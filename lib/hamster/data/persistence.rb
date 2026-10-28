# frozen_string_literal: true

module Hamster
  module Persistence
    include Record

    module ClassMethods
      include Record

      def connection
        Record.connection
      end

      def write_table_name
        if schema_name == "public" && table_name.match?(/\A[a-z_][a-z0-9_]*\z/)
          table_name
        else
          %Q("#{schema_name.gsub('"', '""')}"."#{table_name.gsub('"', '""')}")
        end
      end

      def create_fields
        columns.select { |_name, definition| [:create, :both].include?(definition[:write]) }.keys.map(&:to_s)
      end

      def update_fields
        columns.select { |_name, definition| [:update, :both].include?(definition[:write]) }.keys.map(&:to_s)
      end

      def create(**attributes)
        Instrumentation.record(name, "create") { persist_create(**attributes) }
      end

      # Shared persistence path; the caller owns the record boundary.
      def persist_create(**attributes)
        check_fields!(attributes, create_fields)
        record = new(**attributes)
        errors = validate_create(attributes)
        return Result.new(record: record, code: :invalid, errors: errors) unless errors.empty?

        now = Time.now.utc.iso8601
        timestamps = %w[created_at updated_at].select { |name| self.columns.key?(name.to_sym) }
        columns = create_fields + timestamps
        values = create_fields.map { |name| attributes[name.to_sym] } + timestamps.map { now }
        placeholders = (1..columns.length).map { |number| "$#{number}" }.join(", ")
        sql = "INSERT INTO #{write_table_name} (#{columns.join(', ')}) VALUES (#{placeholders}) " \
              "RETURNING #{(['id'] + timestamps).join(', ')}"
        row = connection.execute(sql, values).hashes.first
        return Result.new(record: record, code: :database_error, errors: ["Could not save record."]) unless row

        record.id = row["id"]
        record.write_attribute(:created_at, row["created_at"]) if self.columns.key?(:created_at)
        record.write_attribute(:updated_at, row["updated_at"]) if self.columns.key?(:updated_at)
        Result.new(record: record)
      rescue Hamster::Database::Error => error
        database_failure(record, error)
      end
      private :persist_create

      def create!(**attributes)
        create(**attributes).value!
      end

      def validate_create(_attributes)
        []
      end

      def check_fields!(attributes, allowed)
        unknown = attributes.keys.map(&:to_s) - allowed
        raise ArgumentError, "Undeclared record fields: #{unknown.join(', ')}" unless unknown.empty?
      end

      def database_failure(record, error)
        if error.is_a?(Hamster::Database::QueryError) && error.sqlstate == "23505"
          Result.new(record: record, code: :conflict, errors: ["Record already exists."], cause: error)
        else
          Result.new(record: record, code: :database_error, errors: ["Could not save record."], cause: error)
        end
      end
    end

    def update(**changes)
      Instrumentation.record(self.class.name, "update") do
        self.class.check_fields!(changes, self.class.update_fields)
        next missing_result if id.nil? || destroyed?
        next Result.new(record: self, code: :invalid, errors: ["No changes supplied."]) if changes.empty?

        errors = validate_update(changes)
        next Result.new(record: self, code: :invalid, errors: errors) unless errors.empty?

        now = Time.now.utc.iso8601
        columns = self.class.update_fields.select { |name| changes.key?(name.to_sym) }
        values = columns.map { |name| changes[name.to_sym] }
        timestamps = self.class.columns.key?(:updated_at)
        columns << "updated_at" if timestamps
        values << now if timestamps
        assignments = columns.each_with_index.map { |name, index| "#{name} = $#{index + 1}" }.join(", ")
        returning = timestamps ? "updated_at" : "id"
        sql = "UPDATE #{self.class.write_table_name} SET #{assignments} WHERE id = $#{values.length + 1} RETURNING #{returning}"
        row = self.class.connection.execute(sql, values + [id]).hashes.first
        next missing_result unless row

        apply_changes(changes)
        write_attribute(:updated_at, row["updated_at"]) if timestamps
        Result.new(record: self)
      rescue Hamster::Database::Error => error
        self.class.database_failure(self, error)
      end
    end

    def update!(**changes)
      update(**changes).value!
    end

    def destroy
      Instrumentation.record(self.class.name, "destroy") do
        next missing_result if id.nil? || destroyed?

        sql = "DELETE FROM #{self.class.write_table_name} WHERE id = $1 RETURNING id"
        row = self.class.connection.execute(sql, [id]).hashes.first
        next missing_result unless row

        @destroyed = true
        Result.new(record: self)
      rescue Hamster::Database::Error => error
        self.class.database_failure(self, error)
      end
    end

    def destroy!
      destroy.value!
    end

    def destroyed?
      @destroyed == true
    end

    def validate_update(_changes)
      []
    end

    def apply_changes(changes)
      changes.each { |name, value| write_attribute(name, value) }
    end

    private

    def missing_result
      Result.new(record: self, code: :not_found, errors: ["Record not found."])
    end
  end
end
