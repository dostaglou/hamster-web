# frozen_string_literal: true

module Hamster
  module Read
    class Schema
      def self.validate(connection, tables = Table.registry)
        report(connection, tables)["errors"]
      end

      # A LEFT JOIN preserves physical existence even for zero-column relations.
      # Disabled declarations are informational; they never trigger migrations.
      def self.report(connection, tables = Table.registry)
        errors = []
        declarations = tables.map do |table|
          catalog = connection.execute(<<~SQL, [table.schema_name, table.table_name]).hashes
            SELECT a.attname AS name, a.atttypid::text AS type_id,
                   a.attnotnull::text AS not_null
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_catalog.pg_attribute a ON c.oid = a.attrelid
              AND a.attnum > 0 AND NOT a.attisdropped
            WHERE n.nspname = $1 AND c.relname = $2
              AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
          SQL
          exists = !catalog.empty?
          prefix = "#{table.schema_name}.#{table.table_name}"
          errors << "#{prefix}: table is missing" if table.enabled? && !exists
          columns = table.columns.map do |name, definition|
            actual = catalog.find { |row| row["name"] == name.to_s }
            checked = table.enabled? && definition[:enabled] && exists
            if checked
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
            {"name" => name.to_s, "enabled" => definition[:enabled], "exists" => !actual.nil?, "checked" => checked}
          end
          {"schema" => table.schema_name, "table" => table.table_name, "enabled" => table.enabled?,
           "exists" => exists, "columns" => columns}
        end
        {"format_version" => 1, "valid" => errors.empty?, "tables" => declarations, "errors" => errors}
      end
    end
  end
end
