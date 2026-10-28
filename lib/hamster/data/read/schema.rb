# frozen_string_literal: true

module Hamster
  module Read
    class Schema
      def self.validate(connection, tables = Table.registry)
        errors = []
        tables.each do |table|
          catalog = connection.execute(<<~SQL, [table.schema_name, table.table_name]).hashes
            SELECT a.attname AS name, a.atttypid::text AS type_id,
                   a.attnotnull::text AS not_null
            FROM pg_catalog.pg_attribute a
            JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relname = $2
              AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
              AND a.attnum > 0 AND NOT a.attisdropped
          SQL
          prefix = "#{table.schema_name}.#{table.table_name}"
          errors << "#{prefix}: table is missing" if catalog.empty?
          table.columns.each do |name, definition|
            next unless definition[:enabled]
            actual = catalog.find { |row| row["name"] == name.to_s }
            if actual.nil?
              errors << "#{prefix}.#{name}: column is missing"
            else
              unless actual["type_id"] == TYPES[definition[:type]].to_s
                errors << "#{prefix}.#{name}: incompatible type (expected #{definition[:type]})"
              end
              if !definition[:nullable] && actual["not_null"] != "true"
                errors << "#{prefix}.#{name}: database permits NULL"
              end
            end
          end
        end
        errors
      end
    end
  end
end
