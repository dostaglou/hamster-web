# frozen_string_literal: true

module Hamster
  # The web runtime works without a telemetry backend. The telemetry entry point
  # can replace this boundary while preserving the instrumented block's result.
  module Instrumentation
    SQL_OPERATIONS = %w[SELECT INSERT UPDATE DELETE BEGIN COMMIT ROLLBACK CREATE ALTER DROP TRUNCATE WITH SAVEPOINT RELEASE].freeze

    def self.sql_operation(sql)
      operation = sql.lstrip.split(/\s+/, 2).first.to_s.upcase
      SQL_OPERATIONS.include?(operation) ? operation : "OTHER"
    end

    def self.diagnostic
      $stderr.write("HAMSTER_TELEMETRY_FAILED\n")
    rescue StandardError
      nil
    end

    def self.instrument(name, attributes: {}, kind: "internal")
      yield({})
    end
  end
end
