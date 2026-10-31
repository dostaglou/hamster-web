# frozen_string_literal: true
require "securerandom"
require_relative "data"
require_relative "database/migrator"

module Hamster
  module Testing
    # Own a fresh database for the duration of the block; never reuse a named DB.
    module TestDatabase
      module_function
      def configuration(env)
        raise ArgumentError, "Test databases require HAMSTER_ENV=test" unless env["HAMSTER_ENV"] == "test"
        raise ArgumentError, "Use HAMSTER_TEST_DATABASE=1 to opt into disposable DB tests" unless env["HAMSTER_TEST_DATABASE"] == "1"
        raise ArgumentError, "DATABASE_URL is not accepted for test databases" if env["DATABASE_URL"]
        raise ArgumentError, "Use TEST_DATABASE_* settings, not DATABASE_NAME" if env["DATABASE_NAME"]
        host = env.fetch("TEST_DATABASE_HOST", "127.0.0.1")
        unless %w[127.0.0.1 localhost ::1].include?(host) || env["HAMSTER_TEST_ALLOW_REMOTE"] == "1"
          raise ArgumentError, "Remote test hosts require HAMSTER_TEST_ALLOW_REMOTE=1"
        end
        values = {"DATABASE_USERNAME" => env.fetch("TEST_DATABASE_USERNAME"), "DATABASE_PASSWORD" => env.fetch("TEST_DATABASE_PASSWORD", ""),
                  "DATABASE_HOST" => host, "DATABASE_PORT" => env.fetch("TEST_DATABASE_PORT", "5432"),
                  "DATABASE_NAME" => "hamster_test_#{Process.pid}_#{SecureRandom.hex(8)}", "HAMSTER_ENV" => "test",
                  "DATABASE_ADMIN_NAME" => "postgres", "DATABASE_ADMIN_USERNAME" => env.fetch("TEST_DATABASE_ADMIN_USERNAME", env.fetch("TEST_DATABASE_USERNAME")),
                  "DATABASE_ADMIN_PASSWORD" => env.fetch("TEST_DATABASE_ADMIN_PASSWORD", env.fetch("TEST_DATABASE_PASSWORD", ""))}
        Database::Configuration.from_env(values)
      end
      def rollback(database)
        database.with_connection do |connection|
          raise "Test transaction requires an idle connection" unless connection.idle?
          connection.execute("BEGIN")
          begin
            yield connection
          ensure
            connection.execute("ROLLBACK") unless connection.idle?
          end
        end
      end
      def with_database(migrations_path:, env: ENV)
        config = configuration(env)
        # Load only after guardrails pass. Apps make the vendored pg driver available.
        require_relative "database/postgres"
        created = Database::Admin.create!(config)
        raise "Refusing to reuse an existing test database" unless created
        database = Database.new(config, migrations_path: migrations_path)
        begin
          database.migrate!
          yield database
        ensure
          database.shutdown
          admin = Database::Configuration.new(adapter: "postgres", host: config.host, port: config.port, database: "postgres",
            username: config.admin_username, password: config.admin_password, pool_size: 1, checkout_timeout: 5)
          connection = Database::Connection.new(Database::Postgres.connect(admin))
          begin
            raise "Unsafe test database name" unless config.database.match?(/\Ahamster_test_[0-9]+_[0-9a-f]{16}\z/)
            connection.execute_script("DROP DATABASE \"#{config.database}\"")
          ensure
            connection.close
          end
        end
      end
    end
  end
end
