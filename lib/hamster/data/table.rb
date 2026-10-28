# frozen_string_literal: true

module Hamster
  class Table
    include Record
    include Persistence
    extend Persistence::ClassMethods

    REGISTRY = []

    def self.inherited(child)
      child.set_metadata(table_name, schema_name, columns) unless self == Table
      REGISTRY << child
    end

    def self.set_metadata(name, schema, definitions)
      @table_name = name
      @schema_name = schema
      @columns = definitions.dup
    end

    def self.registry
      REGISTRY.dup.freeze
    end

    def self.table(name, schema: "public")
      @table_name = Read.identifier(name)
      @schema_name = Read.identifier(schema)
    end

    def self.table_name
      @table_name || name.split("::").last.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase + "s"
    end

    def self.schema_name
      @schema_name || "public"
    end

    def self.columns
      (@columns || {}).dup.freeze
    end

    def self.column(name, type:, nullable: true, enabled: true, write: :none)
      register_column(name, type: type, nullable: nullable, enabled: enabled, write: write)
      # Spinel expands these names from literal column declarations at compile time.
      if RUBY_ENGINE == "ruby"
        define_method("#{name}") { self[name] }
        define_method("#{name}=") { |value| write_attribute(name, value) }
      end
    end

    def self.register_column(name, type:, nullable:, enabled:, write:)
      raise Read::ValidationError, "Unsupported column type #{type}" unless Read::TYPES.key?(type)
      unless [true, false].include?(nullable) && [true, false].include?(enabled)
        raise Read::ValidationError, "Column flags must be boolean"
      end
      unless [:none, :create, :update, :both].include?(write)
        raise Read::ValidationError, "Column write must be :none, :create, :update, or :both"
      end
      key = Read.identifier(name).to_sym
      unless key.to_s.match?(/\A[a-z_][a-z0-9_]*\z/)
        raise Read::ValidationError, "Column #{key} cannot be used as a record accessor"
      end
      if Table.method_defined?(key) || Table.private_method_defined?(key) ||
         Table.method_defined?("#{key}=") || Table.private_method_defined?("#{key}=")
        raise Read::ValidationError, "Column #{key} would shadow a record method"
      end
      @columns = columns.merge(key => { type: type, nullable: nullable, enabled: enabled, write: write }.freeze)
    end

    def self.[](name); Read::Source.new(self)[name]; end
    def self.as(name); Read::Source.new(self, name); end
    def self.all; Read::Source.new(self).all; end
    def self.first(connection: nil); all.first(connection: connection); end
    def self.last(connection: nil); all.last(connection: connection); end
    def self.count(connection: nil); all.count(connection: connection); end
    def self.select(*items); all.select(*items); end
    def self.reselect(*items); all.reselect(*items); end
    def self.group(*items); all.group(*items); end
    def self.order(*items); all.order(*items); end
    def self.reorder(*items); all.reorder(*items); end
    def self.where(value); all.where(value); end
    def self.having(value); all.having(value); end
    def self.limit(value); all.limit(value); end
    def self.offset(value); all.offset(value); end
    def self.distinct(enabled = true); all.distinct(enabled); end
    def self.joins(source, on:); all.joins(source, on: on); end
    def self.left_joins(source, on:); all.left_joins(source, on: on); end
  end
end
