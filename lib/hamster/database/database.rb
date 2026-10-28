# frozen_string_literal: true

module Hamster
  class Database
    attr_reader :configuration

    def initialize(configuration, migrations_path:)
      @configuration = configuration
      @migrations_path = File.expand_path(migrations_path)
      @pool = Pool.new(configuration)
    end

    # Database boundaries own SQLSTATE classification, never the telemetry core.
    def self.telemetry_error(details, error)
      state = error.sqlstate
      if state.instance_of?(String) && state.valid_encoding? && state.match?(/\A[0-9A-Z]{5}\z/)
        details["db.response.status_code"] = state
      end
    rescue StandardError
      Hamster::Instrumentation.diagnostic
    end

    def with_connection
      connection = Hamster::Instrumentation.instrument("db.checkout", attributes: {"db.system.name" => "postgresql"}) do |details|
        begin
          @pool.checkout
        rescue Error => error
          Database.telemetry_error(details, error)
          raise
        end
      end
      begin
        Hamster::Record.with_connection(connection) { yield connection }
      ensure
        @pool.checkin(connection)
      end
    end

    def migrate!
      with_connection do |connection|
        connection.transaction do
          connection.execute(<<~SQL)
            CREATE TABLE IF NOT EXISTS schema_migrations (
              version TEXT PRIMARY KEY,
              applied_at TIMESTAMPTZ NOT NULL
            )
          SQL

          applied = rows(connection, "SELECT version FROM schema_migrations ORDER BY version")
          migration_files.each do |version, path|
            next if applied.any? { |row| row["version"] == version }

            connection.execute_script(File.read(path))
            connection.execute("INSERT INTO schema_migrations (version, applied_at) VALUES ($1, $2)",
                               [version, Time.now.utc.iso8601])
          end
        end
      end
      true
    end

    def verify!
      with_connection do |connection|
        present = rows(connection, "SELECT to_regclass('public.schema_migrations') AS name")
        raise ConfigurationError, "migration tracking is missing; run bin/hamster db:migrate" if present.first["name"].nil?
        applied = rows(connection, "SELECT version FROM schema_migrations ORDER BY version").map { |row| row["version"] }
        missing = migration_files.map(&:first) - applied
        raise ConfigurationError, "pending migrations #{missing.join(', ')}; run bin/hamster db:migrate" unless missing.empty?
      end
      true
    end

    def shutdown
      @pool.shutdown
    end

    private

    def rows(connection, sql, params = [])
      connection.execute(sql, params).hashes
    end

    def migration_files
      files = Dir[File.join(@migrations_path, "*.sql")].sort.map do |path|
        [File.basename(path, ".sql").split("_", 2).first, path]
      end
      versions = files.map(&:first)
      raise ConfigurationError, "duplicate migration versions" unless versions.uniq.length == versions.length
      files
    end
  end
end
