# frozen_string_literal: true

module Hamster
  class Database
    class Configuration
      attr_reader :adapter, :host, :port, :database, :username, :password,
                  :pool_size, :checkout_timeout, :admin_database,
                  :admin_username, :admin_password

      def initialize(adapter:, host:, port:, database:, username:, password:, pool_size:, checkout_timeout:,
                     admin_database: "postgres", admin_username: nil, admin_password: nil)
        @adapter = adapter.to_s
        @host = host.to_s
        @port = integer_value(port, "port")
        @database = database.to_s
        @username = username.to_s
        @password = password.to_s
        @pool_size = integer_value(pool_size, "pool_size")
        @checkout_timeout = float_value(checkout_timeout, "checkout_timeout")
        @admin_database = admin_database.to_s
        @admin_username = (admin_username || username).to_s
        @admin_password = (admin_password || password).to_s
        validate!
      end

      def self.from_env(env = ENV, app_name: "hamster")
        if env.key?("DATABASE_TLS") || env.key?("DATABASE_SSLMODE")
          raise ConfigurationError, "database TLS settings are unsupported by the postgres adapter"
        end

        adapter = env.fetch("DATABASE_ADAPTER", "postgres").dup
        host = env.fetch("DATABASE_HOST", "127.0.0.1").dup
        port = env.fetch("DATABASE_PORT", "5432").dup
        app_name = env.fetch("HAMSTER_APP_NAME", app_name).dup
        environment = env.fetch("HAMSTER_ENV", "development").dup
        database = env.fetch("DATABASE_NAME", "#{app_name}_#{environment}").dup
        username = env.fetch("DATABASE_USERNAME").dup
        password = env.fetch("DATABASE_PASSWORD", "").dup
        admin_database = env.fetch("DATABASE_ADMIN_NAME", "postgres").dup
        admin_username = env.fetch("DATABASE_ADMIN_USERNAME", username).dup
        admin_password = env.fetch("DATABASE_ADMIN_PASSWORD", password).dup
        pool_size = env.fetch("DATABASE_POOL_SIZE", "5").dup
        checkout_timeout = env.fetch("DATABASE_CHECKOUT_TIMEOUT", "5.0").dup
        new(
          adapter: adapter, host: host, port: port, database: database,
          username: username, password: password, pool_size: pool_size,
          checkout_timeout: checkout_timeout, admin_database: admin_database,
          admin_username: admin_username, admin_password: admin_password
        )
      rescue KeyError => error
        raise ConfigurationError, "missing database setting #{error.key}"
      end

      private

      def integer_value(value, name)
        Integer(value)
      rescue ArgumentError, TypeError
        raise ConfigurationError, "database #{name} must be an integer"
      end

      def float_value(value, name)
        Float(value)
      rescue ArgumentError, TypeError
        raise ConfigurationError, "database #{name} must be a number"
      end

      def validate!
        raise ConfigurationError, "unsupported database adapter #{adapter.inspect}" unless adapter == "postgres"
        raise ConfigurationError, "database host must not be empty" if host.empty?
        raise ConfigurationError, "database port must be between 1 and 65535" unless port.between?(1, 65_535)
        raise ConfigurationError, "database name must not be empty" if database.empty?
        unless database.match?(/\A[a-z_][a-z0-9_]*\z/)
          raise ConfigurationError, "database name must be a lowercase PostgreSQL identifier"
        end
        raise ConfigurationError, "database admin name must not be empty" if admin_database.empty?
        raise ConfigurationError, "database admin username must not be empty" if admin_username.empty?
        raise ConfigurationError, "database username must not be empty" if username.empty?
        raise ConfigurationError, "database pool_size must be positive" unless pool_size.positive?
        raise ConfigurationError, "database checkout_timeout must be positive" unless checkout_timeout.positive?
      end
    end
  end
end
