# frozen_string_literal: true

module Hamster
  class Database
    class Admin
      def self.create!(configuration)
        connection = Connection.new(Postgres.connect(admin_configuration(configuration)))
        existing = connection.execute("SELECT 1 FROM pg_database WHERE datname = $1", [configuration.database])
        return false unless existing.rows.empty?

        connection.execute_script("CREATE DATABASE #{quote_identifier(configuration.database)}")
        true
      ensure
        connection&.close
      end

      def self.admin_configuration(configuration)
        Configuration.new(
          adapter: configuration.adapter,
          host: configuration.host,
          port: configuration.port,
          database: configuration.admin_database,
          username: configuration.admin_username,
          password: configuration.admin_password,
          pool_size: 1,
          checkout_timeout: configuration.checkout_timeout
        )
      end

      def self.quote_identifier(identifier)
        raise ConfigurationError, "unsafe database name" unless identifier.match?(/\A[a-z_][a-z0-9_]*\z/)

        "\"#{identifier}\""
      end

      private_class_method :admin_configuration, :quote_identifier
    end
  end
end
