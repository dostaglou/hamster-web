# frozen_string_literal: true
require_relative "../jobs"
require_relative "../data"
module Hamster
  module Jobs
    class LostLease < Error; end
    class PostgresQueue
      attr_reader :database, :lease_seconds
      def self.migration_sql
        <<~SQL
          CREATE TABLE hamster_job_settings (name TEXT PRIMARY KEY, version INTEGER NOT NULL);
          INSERT INTO hamster_job_settings(name,version) VALUES('format',1);
          CREATE TABLE hamster_jobs (
            id TEXT PRIMARY KEY, payload TEXT NOT NULL, queue TEXT NOT NULL,
            priority INTEGER NOT NULL DEFAULT 0,
            state TEXT NOT NULL CHECK(state IN ('pending','running','completed','dead','cancelled')),
            run_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
            attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts >= 0),
            max_attempts INTEGER NOT NULL CHECK(max_attempts > 0),
            lease_token TEXT, leased_until TIMESTAMPTZ, locked_by TEXT,
            cancel_requested BOOLEAN NOT NULL DEFAULT FALSE, error_class TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP, finished_at TIMESTAMPTZ
          );
          CREATE INDEX hamster_jobs_pending ON hamster_jobs(queue,priority DESC,run_at,id) WHERE state='pending';
          CREATE INDEX hamster_jobs_leases ON hamster_jobs(leased_until) WHERE state='running';
        SQL
      end
      def initialize(database:, queue: "default", max_attempts: 5, lease_seconds: 30.0, retry_base_seconds: 1.0, max_retry_seconds: 300.0)
        @database, @queue, @max_attempts = database, queue, max_attempts
        validate_queue(queue)
        raise ArgumentError, "max attempts must be a positive integer" unless max_attempts.is_a?(Integer) && max_attempts > 0 && max_attempts <= 1000
        [lease_seconds, retry_base_seconds, max_retry_seconds].each { |n| raise ArgumentError, "queue times must be positive and finite" unless n.is_a?(Numeric) && n.finite? && n > 0 }
        @lease_seconds, @retry_base, @max_retry = lease_seconds, retry_base_seconds, max_retry_seconds
      end
      def validate_queue(name)
        raise ArgumentError, "invalid queue name" unless name.is_a?(String) && name.match?(/\A[a-z][a-z0-9_-]{0,63}\z/)
      end
      def verify!
        rows = database.with_connection { |c| c.execute("SELECT version FROM hamster_job_settings WHERE name='format'").hashes }
        raise Error, "Unsupported job schema; apply the compatible queue migration" unless rows.first && rows.first["version"] == "1"
        true
      end
      def enqueue(bytes, at: nil, queue: nil, priority: nil, connection: nil)
        value = Jobs.validate(bytes)
        selected = queue || @queue
        validate_queue(selected)
        rank = priority || 0
        raise ArgumentError, "priority must be an integer" unless rank.is_a?(Integer) && rank >= -2147483648 && rank <= 2147483647
        raise ArgumentError, "schedule must be a Time" if at && !at.is_a?(Time)
        sql = "INSERT INTO hamster_jobs(id,payload,queue,priority,state,run_at,max_attempts) VALUES($1,$2,$3,$4,'pending',$5,$6) ON CONFLICT(id) DO NOTHING RETURNING id"
        binds = [value.fetch("id"), bytes, selected, rank, at || Time.now.utc, @max_attempts]
        if connection
          expected = database.configuration.database
          actual = connection.execute("SELECT current_database() AS name").hashes.first["name"]
          raise Error, "Enqueue connection belongs to a different database" unless actual == expected
          insert_envelope(connection, sql, binds, bytes, selected, rank)
        else
          database.with_connection { |c| insert_envelope(c, sql, binds, bytes, selected, rank) }
        end
        value.fetch("id")
      end
      def insert_envelope(connection, sql, binds, bytes, selected, priority)
        return unless connection.execute(sql, binds).rows.empty?
        previous = connection.execute("SELECT payload,queue,priority FROM hamster_jobs WHERE id=$1", [binds[0]]).hashes.first
        unless previous && previous["payload"] == bytes && previous["queue"] == selected && previous["priority"].to_i == priority
          raise PayloadError, "Job ID already belongs to a different payload"
        end
      end
      def recover_expired!
        database.with_connection do |c|
          c.execute(<<~SQL)
            UPDATE hamster_jobs SET
              state=CASE WHEN cancel_requested THEN 'cancelled' WHEN attempts>=max_attempts THEN 'dead' ELSE 'pending' END,
              run_at=CURRENT_TIMESTAMP, lease_token=NULL, leased_until=NULL, locked_by=NULL,
              error_class='LeaseExpired', updated_at=CURRENT_TIMESTAMP,
              finished_at=CASE WHEN cancel_requested OR attempts>=max_attempts THEN CURRENT_TIMESTAMP ELSE NULL END
            WHERE state='running' AND leased_until<=CURRENT_TIMESTAMP
          SQL
        end
      end
      def claim(worker_id, queues: ["default"])
        raise ArgumentError, "choose 1..32 queues" unless queues.is_a?(Array) && queues.length >= 1 && queues.length <= 32
        queues.each { |queue| validate_queue(queue) }
        token = SecureRandom.hex(16)
        placeholders = queues.each_index.map { |i| "$#{i + 1}" }.join(",")
        n = queues.length
        sql = <<~SQL
          WITH candidate AS (
            SELECT id FROM hamster_jobs
            WHERE state='pending' AND run_at<=CURRENT_TIMESTAMP AND queue IN (#{placeholders})
            ORDER BY priority DESC,run_at,id FOR UPDATE SKIP LOCKED LIMIT 1
          )
          UPDATE hamster_jobs j SET state='running',attempts=j.attempts+1,
            lease_token=$#{n + 1},leased_until=CURRENT_TIMESTAMP+($#{n + 2}::double precision*INTERVAL '1 second'),
            locked_by=$#{n + 3},updated_at=CURRENT_TIMESTAMP
          FROM candidate WHERE j.id=candidate.id RETURNING j.*
        SQL
        database.with_connection { |c| c.execute(sql, queues + [token, lease_seconds.to_s, worker_id]).hashes.first }
      end
      def renew(id, token)
        sql = "UPDATE hamster_jobs SET leased_until=CURRENT_TIMESTAMP+($1::double precision*INTERVAL '1 second'),updated_at=CURRENT_TIMESTAMP WHERE id=$2 AND lease_token=$3 AND state='running' AND leased_until>CURRENT_TIMESTAMP RETURNING cancel_requested::text AS cancelled"
        row = database.with_connection { |c| c.execute(sql, [lease_seconds.to_s, id, token]).hashes.first }
        raise LostLease, "Job lease is no longer owned" unless row
        row["cancelled"] == "true"
      end
      def complete(id, token)
        sql = "UPDATE hamster_jobs SET state=CASE WHEN cancel_requested THEN 'cancelled' ELSE 'completed' END,finished_at=CURRENT_TIMESTAMP,updated_at=CURRENT_TIMESTAMP,lease_token=NULL,leased_until=NULL,locked_by=NULL WHERE id=$1 AND lease_token=$2 AND state='running' AND leased_until>CURRENT_TIMESTAMP RETURNING id"
        rows = database.with_connection { |c| c.execute(sql, [id, token]).rows }
        raise LostLease, "Cannot complete a lost job lease" if rows.empty?
        true
      end
      def fail_job(row, error_class)
        delay = [@retry_base * (2 ** [row.fetch("attempts").to_i - 1, 30].min), @max_retry].min
        sql = <<~SQL
          UPDATE hamster_jobs SET state=CASE WHEN cancel_requested THEN 'cancelled' WHEN attempts>=max_attempts THEN 'dead' ELSE 'pending' END,
            run_at=CURRENT_TIMESTAMP+($1::double precision*INTERVAL '1 second'),
            error_class=$2,updated_at=CURRENT_TIMESTAMP,
            finished_at=CASE WHEN cancel_requested OR attempts>=max_attempts THEN CURRENT_TIMESTAMP ELSE NULL END,
            lease_token=NULL,leased_until=NULL,locked_by=NULL
          WHERE id=$3 AND lease_token=$4 AND state='running' AND leased_until>CURRENT_TIMESTAMP RETURNING id
        SQL
        rows = database.with_connection { |c| c.execute(sql, [delay.to_s, error_class.to_s[0, 200], row.fetch("id"), row.fetch("lease_token")]).rows }
        raise LostLease, "Cannot fail a lost job lease" if rows.empty?
        true
      end
      def cancel(id)
        sql = "UPDATE hamster_jobs SET cancel_requested=TRUE,state=CASE WHEN state='pending' THEN 'cancelled' ELSE state END,finished_at=CASE WHEN state='pending' THEN CURRENT_TIMESTAMP ELSE finished_at END,updated_at=CURRENT_TIMESTAMP WHERE id=$1 AND state IN ('pending','running') RETURNING id"
        database.with_connection { |c| !c.execute(sql, [id]).rows.empty? }
      end
      def retry_dead(id, at: Time.now.utc)
        sql = "UPDATE hamster_jobs SET state='pending',attempts=0,cancel_requested=FALSE,error_class=NULL,finished_at=NULL,run_at=$1,updated_at=CURRENT_TIMESTAMP WHERE id=$2 AND state='dead' RETURNING id"
        database.with_connection { |c| !c.execute(sql, [at, id]).rows.empty? }
      end
      def status
        database.with_connection do |c|
          counts = c.execute("SELECT state,count(*)::text AS count FROM hamster_jobs GROUP BY state ORDER BY state").hashes.to_h { |row| [row["state"], row["count"].to_i] }
          oldest = c.execute("SELECT min(run_at)::text AS oldest FROM hamster_jobs WHERE state='pending'").hashes.first["oldest"]
          due = c.execute("SELECT count(*)::text AS count FROM hamster_jobs WHERE state='pending' AND run_at<=CURRENT_TIMESTAMP").hashes.first["count"].to_i
          {"format_version" => 1, "counts" => counts, "ready" => due, "scheduled" => counts.fetch("pending", 0) - due, "oldest_pending_at" => oldest}
        end
      end
      def shutdown(timeout: 10.0); true; end
    end
  end
end
