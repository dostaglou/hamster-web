# frozen_string_literal: true


module Hamster
  class Database
    class Connection
      attr_reader :raw

      def initialize(raw)
        @raw = raw
        @usable = true
      end

      def execute(sql, params = [])
        Hamster::Instrumentation.instrument("db.execute", attributes: {"db.system.name" => "postgresql", "db.operation.name" => Hamster::Instrumentation.sql_operation(sql)}, kind: "client") do |details|
          begin
            execute_statement(sql, params)
          rescue Error => error
            Database.telemetry_error(details, error)
            raise
          end
        end
      end

      def execute_statement(sql, params)
        values = serialize_params(params)
        result = raw.exec_params(sql, values)
        result_object(result)
      rescue ArgumentError => error
        raise error
      rescue PG::Error => error
        mark_unusable unless usable_status?
        raise QueryError.new("database query failed", original: error,
                             sqlstate: Postgres.sqlstate(error))
      rescue StandardError => error
        mark_unusable unless usable_status?
        raise error if error.is_a?(Error)

        raise ConnectionError.new("database operation failed: #{error.message}", original: error)
      end

      def execute_script(sql)
        Hamster::Instrumentation.instrument("db.execute_script", attributes: {"db.system.name" => "postgresql", "db.operation.name" => "SCRIPT"}, kind: "client") do |details|
          begin
            execute_script_statement(sql)
          rescue Error => error
            Database.telemetry_error(details, error)
            raise
          end
        end
      end

      def execute_script_statement(sql)
        result_object(raw.exec(sql))
      rescue PG::Error => error
        mark_unusable unless usable_status?
        raise QueryError.new("database query failed", original: error,
                             sqlstate: Postgres.sqlstate(error))
      rescue StandardError => error
        mark_unusable unless usable_status?
        raise error if error.is_a?(Error)

        raise ConnectionError.new("database operation failed: #{error.message}", original: error)
      end

      def transaction
        raise TransactionError, "nested transactions are not supported" unless idle?

        execute("BEGIN")
        begin
          result = yield self
          execute("COMMIT")
          result
        rescue StandardError => original
          begin
            execute("ROLLBACK") unless idle?
          rescue StandardError
            mark_unusable
          end
          raise original
        end
      end

      def idle?
        raw.transaction_status == PG::PQTRANS_IDLE
      rescue StandardError
        false
      end

      def usable?
        @usable && raw.transaction_status != PG::PQTRANS_UNKNOWN
      rescue StandardError
        false
      end

      def close
        raw.close unless raw.transaction_status == PG::PQTRANS_UNKNOWN
      rescue StandardError
        mark_unusable
      ensure
        @usable = false
      end

      def mark_unusable
        @usable = false
      end

      private

      private :execute_statement, :execute_script_statement

      def usable_status?
        raw.transaction_status != PG::PQTRANS_UNKNOWN
      rescue StandardError
        false
      end

      def serialize_params(params)
        raise ArgumentError, "database parameters must be an Array" unless params.is_a?(Array)

        params.map do |value|
          case value
          when NilClass, String then value
          when Integer then value.to_s
          when Time then value.iso8601(6)
          when DateTime then value.iso8601(6)
          when Date then value.iso8601
          when TrueClass then "true"
          when FalseClass then "false"
          else
            raise ArgumentError, "unsupported database parameter #{value.class}"
          end
        end
      end

      def copy_rows(result)
        rows = []
        row_index = 0
        while row_index < result.ntuples
          row = []
          column_index = 0
          while column_index < result.nfields
            row << result.getvalue(row_index, column_index)
            column_index += 1
          end
          rows << row
          row_index += 1
        end
        rows
      end

      def result_object(result)
        Result.new(columns: result.fields.dup, rows: copy_rows(result), types: copy_types(result),
                   command_tag: result.cmd_tag)
      end

      def copy_types(result)
        types = []
        column_index = 0
        while column_index < result.nfields
          types << result.ftype(column_index)
          column_index += 1
        end
        types
      end
    end
  end
end
