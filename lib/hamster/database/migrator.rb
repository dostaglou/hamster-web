# frozen_string_literal: true
# Tooling only: never require this file from hamster/web or hamster/data.
require "digest"
require "json"
require_relative "../migration"

module Hamster
  class Database
    class Migrator
      def initialize(database, path)
        @database, @path = database, path
      end

      def files
        entries = Dir[File.join(@path, "*.{rb,sql}")].sort.map do |path|
          name = File.basename(path)
          version = name.split("_", 2).first.sub(/\.(rb|sql)\z/, "")
          raise ConfigurationError, "invalid migration version #{name}" unless version.match?(/\A[0-9]+\z/)
          {"version" => version, "file" => name, "checksum" => Digest::SHA256.file(path).hexdigest}
        end
        raise ConfigurationError, "duplicate migration versions" unless entries.map { |f| f["version"] }.uniq.size == entries.size
        entries.sort_by { |f| f["version"] }
      end

      def tracking(c)
        c.execute("CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL)")
        c.execute("ALTER TABLE schema_migrations ADD COLUMN IF NOT EXISTS file TEXT, ADD COLUMN IF NOT EXISTS checksum TEXT")
        c.execute("CREATE TABLE IF NOT EXISTS hamster_migration_events (id BIGSERIAL PRIMARY KEY, version TEXT NOT NULL, direction TEXT NOT NULL, file TEXT NOT NULL, checksum TEXT NOT NULL, occurred_at TIMESTAMPTZ NOT NULL)")
      end

      def locked
        @database.with_connection do |c|
          c.execute("SELECT pg_advisory_lock(726144807)")
          begin
            c.transaction { tracking(c) }
            yield c
          ensure
            c.execute("SELECT pg_advisory_unlock(726144807)")
          end
        end
      end

      def report(c)
        applied = c.execute("SELECT version, file, checksum, applied_at FROM schema_migrations ORDER BY version").hashes
        disk = files
        versions = (disk + applied).map { |f| f["version"] }.uniq.sort
        versions.map do |v|
          f = disk.find { |e| e["version"] == v }
          row = applied.find { |e| e["version"] == v }
          state = if row.nil? then "pending"
                  elsif f.nil? then "missing"
                  elsif row["checksum"].nil? then "legacy_unknown"
                  elsif row["checksum"] != f["checksum"] || row["file"] != f["file"] then "modified"
                  else "applied" end
          {"version" => v, "file" => f ? f["file"] : row["file"], "status" => state,
           "checksum" => row ? row["checksum"] : f["checksum"], "applied_at" => row && row["applied_at"]}
        end
      end

      def status
        locked { |c| report(c) }
      end

      def history
        locked do |c|
          {"format_version" => 1, "migrations" => report(c),
           "events" => c.execute("SELECT version, direction, file, checksum, occurred_at FROM hamster_migration_events ORDER BY id").hashes}
        end
      end

      def preflight(c)
        rows = report(c)
        bad = rows.select { |r| %w[missing modified].include?(r["status"]) }
        raise ConfigurationError, "migration integrity failure: #{bad.map { |r| r['version'] + ':' + r['status'] }.join(', ')}" unless bad.empty?
        rows
      end

      def migrate!
        locked do |c|
          pending = preflight(c).select { |r| r["status"] == "pending" }
          pending.each { |f| apply(c, f, "up") }
        end
        true
      end

      def rollback!(steps)
        raise ArgumentError, "STEP must be positive" unless steps.is_a?(Integer) && steps > 0
        locked do |c|
          preflight(c)
          selected = c.execute("SELECT version, file, checksum FROM schema_migrations ORDER BY applied_at DESC, version DESC").hashes.take(steps)
          operations = selected.map do |f|
            raise ConfigurationError, "irreversible migration #{f['version']}" unless f["file"]&.end_with?(".rb")
            migration = load_migration(f)
            raise ConfigurationError, "missing down for #{f['version']}" unless migration.respond_to?(:down)
            [f, migration]
          end
          operations.each { |f, m| apply(c, f, "down", m) }
        end
        true
      end

      def load_migration(f)
        scope = Module.new
        Kernel.load(File.join(@path, f.fetch("file")), scope)
        classes = scope.constants(false).map { |name| scope.const_get(name) }.select { |k| k.is_a?(Class) && k < Hamster::Migration }
        raise ConfigurationError, "expected one Hamster::Migration in #{f['file']}" unless classes.size == 1
        classes.first.new
      end

      def apply(c, f, direction, migration = nil)
        c.transaction do
          if f.fetch("file").end_with?(".sql")
            c.execute_script(File.read(File.join(@path, f["file"])))
          else
            migration ||= load_migration(f)
            migration.connection = c
            direction == "up" ? migration.up : migration.down
          end
          now = Time.now.utc.iso8601(6)
          if direction == "up"
            c.execute("INSERT INTO schema_migrations (version, file, checksum, applied_at) VALUES ($1,$2,$3,$4)", [f["version"], f["file"], f["checksum"], now])
          else
            c.execute("DELETE FROM schema_migrations WHERE version = $1", [f["version"]])
          end
          c.execute("INSERT INTO hamster_migration_events (version,direction,file,checksum,occurred_at) VALUES ($1,$2,$3,$4,$5)", [f["version"], direction, f["file"], f["checksum"], now])
        end
      end
    end
  end
end

module Hamster
  class Database
    def migrate!
      Migrator.new(self, @migrations_path).migrate!
    end

    def rollback!(steps = 1)
      Migrator.new(self, @migrations_path).rollback!(steps)
    end

    def migration_status
      Migrator.new(self, @migrations_path).status
    end

    def migration_history
      Migrator.new(self, @migrations_path).history
    end

  end
end
