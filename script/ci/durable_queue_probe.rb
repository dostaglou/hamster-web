require "hamster/test_database"
require "hamster/jobs/worker"
require "timeout"
require "tmpdir"
require "rbconfig"
require "open3"
require_relative "queue_jobs"
processes = []
logs = []
def wait_for
  Timeout.timeout(15) do
    loop do
      begin
        result = yield
        return result if result
      rescue Hamster::Database::Error
        # An intentionally terminated pooled connection is discarded on checkin.
      end
      sleep 0.03
    end
  end
end
Dir.mktmpdir do |root|
  migrations = File.join(root, "migrations")
  Dir.mkdir(migrations)
  sql = Hamster::Jobs::PostgresQueue.migration_sql + "\nCREATE TABLE job_probe_results(id TEXT PRIMARY KEY,total BIGINT,version INTEGER);\nCREATE TABLE job_probe_starts(id TEXT PRIMARY KEY,starts INTEGER);\n"
  File.write(File.join(migrations, "001_jobs.sql"), sql)
  Hamster::Testing::TestDatabase.with_database(migrations_path: migrations) do |database|
    config = database.configuration
    env = {"HAMSTER_ENV" => "test", "DATABASE_HOST" => config.host, "DATABASE_PORT" => config.port.to_s,
           "DATABASE_NAME" => config.database, "DATABASE_USERNAME" => config.username, "DATABASE_PASSWORD" => config.password,
           "DATABASE_POOL_SIZE" => "8", "HAMSTER_TEST_MIGRATIONS" => migrations, "JOB_LEASE_SECONDS" => "2"}
    library = File.expand_path("../../lib", __dir__)
    driver = $LOAD_PATH.find { |path| File.file?(File.join(path, "pg/client.rb")) }
    command = ENV["HAMSTER_NATIVE_WORKER"] ? [ENV.fetch("HAMSTER_NATIVE_WORKER")] : [RbConfig.ruby, "-I", library, "-I", driver, File.join(__dir__, "queue_worker_fixture.rb")]
    spawn_worker = lambda do |extra = {}|
      log = File.join(root, "worker-#{logs.length}.log")
      logs << log
      pid = Process.spawn(env.merge(extra), *command, out: log, err: log, pgroup: true)
      processes << pid
      pid
    end
    stop_worker = lambda do |pid, signal = "TERM"|
      Process.kill(signal, -pid)
      _, status = Timeout.timeout(5) { Process.waitpid2(pid) }
      processes.delete(pid)
      status
    end
    queue = Hamster::Jobs::PostgresQueue.new(database: database, retry_base_seconds: 0.02, lease_seconds: 2)
    queue.verify!
    row = ->(id) { database.with_connection { |c| c.execute("SELECT state,attempts,error_class FROM hamster_jobs WHERE id=$1", [id]).hashes.first } }
    enqueue = ->(key, mode = "normal", version = 2, at = nil) { queue.enqueue(Hamster::Jobs.envelope("queue.probe", version, {"key" => key, "mode" => mode}), at: at) }
    begin
      # Business transaction consistency: rolled-back enqueues never become work.
      database.with_connection do |connection|
        connection.execute("BEGIN")
        queue.enqueue(Hamster::Jobs.envelope("queue.probe", 2, {"key" => "rolled-back"}), connection: connection)
        connection.execute("ROLLBACK")
      end
      raise "enqueue escaped rollback" unless queue.status["counts"].empty?
      duplicate = Hamster::Jobs.envelope("queue.probe", 2, {"key" => "idempotent"})
      twice = queue.enqueue(duplicate)
      raise "enqueue retry changed identity" unless queue.enqueue(duplicate) == twice
      queue.cancel(twice)
      scheduled = enqueue.call("scheduled", "normal", 2, Time.now + 2)
      future = enqueue.call("future", "normal", 2, Time.now + 3600)
      raise "schedule not respected" if queue.claim("early")
      raise "cancel pending" unless queue.cancel(future)
      low = queue.enqueue(Hamster::Jobs.envelope("queue.probe", 2, {"key" => "low"}), priority: -1)
      high = queue.enqueue(Hamster::Jobs.envelope("queue.probe", 2, {"key" => "high"}), priority: 10)
      other = queue.enqueue(Hamster::Jobs.envelope("queue.probe", 2, {"key" => "other"}), queue: "other")
      selected = queue.claim("priority-probe")
      raise "priority order" unless selected["id"] == high
      queue.complete(high, selected["lease_token"])
      selected = queue.claim("priority-probe")
      raise "queue isolation" unless selected["id"] == low
      queue.complete(low, selected["lease_token"])
      selected = queue.claim("queue-probe", queues: ["other"])
      raise "named queue" unless selected["id"] == other
      queue.complete(other, selected["lease_token"])
      ids = 20.times.map { |n| enqueue.call("normal-#{n}", n == 0 ? "cpu" : "normal", n == 1 ? 1 : 2) }
      output, status = Open3.capture2e(env, *command, "--enqueue", "from-compiled-enqueue")
      raise "compiled enqueue failed: #{output}" unless status.success?
      ids << output.lines.last.to_s.strip
      first, second = spawn_worker.call, spawn_worker.call
      wait_for { (ids + [scheduled]).all? { |id| row.call(id)["state"] == "completed" } }
      raise "normal duplicate claim" unless ids.all? { |id| row.call(id)["attempts"] == "1" }
      # Terminate worker connections while running: they must reconnect without
      # losing a newly enqueued job or keeping a dead pooled connection forever.
      database.with_connection do |connection|
        connection.execute("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname=$1 AND pid<>pg_backend_pid()", [config.database])
      end
      outage = enqueue.call("after-outage")
      wait_for { row.call(outage)["state"] == "completed" }
      retry_id = enqueue.call("retry", "retry")
      wait_for { row.call(retry_id)["state"] == "completed" }
      raise "retry count" unless row.call(retry_id)["attempts"] == "2"
      failure_queue = Hamster::Jobs::PostgresQueue.new(database: database, max_attempts: 2, retry_base_seconds: 0.02)
      failed = failure_queue.enqueue(Hamster::Jobs.envelope("queue.probe", 2, {"key" => "failed", "mode" => "fail"}))
      wait_for { row.call(failed)["state"] == "dead" }
      raise "failure privacy" unless row.call(failed)["error_class"] == "ArgumentError"
      slow = enqueue.call("slow", "slow")
      wait_for { row.call(slow)["state"] == "completed" }
      raise "heartbeat duplicate" unless row.call(slow)["attempts"] == "1"
      cancelled = enqueue.call("cancel", "cancel")
      wait_for { row.call(cancelled)["state"] == "running" }
      queue.cancel(cancelled)
      wait_for { row.call(cancelled)["state"] == "cancelled" }
      stop_worker.call(first)
      stop_worker.call(second)
      graceful = enqueue.call("graceful", "graceful")
      draining = spawn_worker.call
      wait_for { row.call(graceful)["state"] == "running" }
      raise "graceful exit" unless stop_worker.call(draining).success?
      raise "graceful work lost" unless row.call(graceful)["state"] == "completed"
      # Kill after user code starts; a new process reclaims only after expiry.
      crashed = enqueue.call("crash", "crash")
      killer = spawn_worker.call("JOB_LEASE_SECONDS" => "0.4")
      wait_for { database.with_connection { |c| !c.execute("SELECT id FROM job_probe_starts WHERE id='crash'").rows.empty? } }
      stop_worker.call(killer, "KILL")
      replacement = spawn_worker.call
      wait_for { row.call(crashed)["state"] == "completed" }
      raise "lease recovery" unless row.call(crashed)["attempts"] == "2"
      stop_worker.call(replacement)
      # Expired tokens cannot acknowledge a later claimant's work.
      stale = enqueue.call("stale")
      short = Hamster::Jobs::PostgresQueue.new(database: database, lease_seconds: 0.05)
      old = short.claim("old")
      sleep 0.08
      queue.recover_expired!
      current = queue.claim("new")
      begin
        queue.complete(stale, old.fetch("lease_token"))
        raise "stale acknowledgement accepted"
      rescue Hamster::Jobs::LostLease
      end
      queue.complete(stale, current.fetch("lease_token"))
      raise "backlog" unless queue.status["counts"]["pending"].to_i == 0
      borrowed = nil
      database.with_connection do |connection|
        borrowed = connection
        database.shutdown
      end
      raise "late checkin leaked" unless borrowed.raw.transaction_status == PG::PQTRANS_UNKNOWN
      raise "worker errors" unless logs.all? { |log| !File.read(log).include?("Error:") }
    rescue Exception
      logs.each { |log| warn File.read(log) if File.file?(log) }
      raise
    ensure
      processes.dup.each { |pid| stop_worker.call(pid, "KILL") rescue nil }
    end
  end
end
puts ENV["HAMSTER_NATIVE_WORKER"] ? "DURABLE_NATIVE_WORKERS_OK" : "DURABLE_RUBY_WORKERS_OK"
