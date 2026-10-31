# frozen_string_literal: true
module Hamster
  class Migration
    attr_writer :connection

    def execute(sql)
      @connection.execute_script(sql)
    end

    def quote(name)
      text = name.to_s
      raise ArgumentError, "invalid identifier" if text.empty? || text.include?("\0")
      '"' + text.gsub('"', '""') + '"'
    end

    def type_sql(type)
      types = {integer: "INTEGER", bigint: "BIGINT", text: "TEXT", string: "VARCHAR(255)", boolean: "BOOLEAN", timestamp: "TIMESTAMP", decimal: "DECIMAL", binary: "BYTEA", date: "DATE", jsonb: "JSONB"}
      types.fetch(type) { raise ArgumentError, "unsupported column type #{type.inspect}; use execute for custom SQL" }
    end

    def create_table(name, columns:)
      definitions = columns.map { |column, type| "#{quote(column)} #{type_sql(type)}" }
      raise ArgumentError, "columns required" if definitions.empty?
      execute("CREATE TABLE #{quote(name)} (#{definitions.join(', ')})")
    end

    def drop_table(name); execute("DROP TABLE #{quote(name)}"); end
    def add_column(table, column, type); execute("ALTER TABLE #{quote(table)} ADD COLUMN #{quote(column)} #{type_sql(type)}"); end
    def remove_column(table, column); execute("ALTER TABLE #{quote(table)} DROP COLUMN #{quote(column)}"); end
    def change_column(table, column, type); execute("ALTER TABLE #{quote(table)} ALTER COLUMN #{quote(column)} TYPE #{type_sql(type)}"); end
    def add_index(table, columns, name:, unique: false)
      execute("CREATE #{unique ? 'UNIQUE ' : ''}INDEX #{quote(name)} ON #{quote(table)} (#{Array(columns).map { |c| quote(c) }.join(', ')})")
    end
    def remove_index(name); execute("DROP INDEX #{quote(name)}"); end
  end
end
