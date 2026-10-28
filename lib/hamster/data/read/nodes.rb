# frozen_string_literal: true

module Hamster
  module Read
    class Error < StandardError; end
    class ValidationError < Error; end
    class DecodeError < Error; end

    TYPES = { integer: 23, bigint: 20, text: 25, boolean: 16, timestamptz: 1184 }.freeze

    def self.snapshot(value)
      case value
      when Array then value.map { |item| snapshot(item) }.freeze
      when Hash
        result = {}
        value.each { |key, item| result[snapshot(key)] = snapshot(item) }
        result.freeze
      when String, Time then value.dup.freeze
      else value
      end
    end

    def self.structural(value)
      case value
      when Node, Source then value.key
      when Array then value.map { |item| structural(item) }
      when Hash
        result = {}
        value.each { |key, item| result[key] = structural(item) }
        result
      else value
      end
    end

    def self.identifier(value)
      name = value.to_s
      raise ValidationError, "Invalid identifier #{name.inspect}" if name.empty? || name.include?("\0")
      name.dup.freeze
    end

    class Source
      attr_reader :row_class, :name, :schema, :label, :columns
      def initialize(row_class, label = nil)
        @row_class = row_class
        @name = row_class.table_name
        @schema = row_class.schema_name
        @label = Read.identifier(label || @name)
        @columns = Read.snapshot(row_class.columns)
        freeze
      end

      def [](name)
        Node.new(:column, [self, name.to_sym])
      end

      def all
        Relation.new(self)
      end

      def key
        [row_class, schema, name, label]
      end
    end

    # One expression representation is shared by validation, compilation and decoding.
    class Node
      attr_reader :kind, :args, :options
      def initialize(kind, args = [], options = {})
        @kind = kind
        @args = Read.snapshot(args)
        @options = Read.snapshot(options)
        freeze
      end

      def key
        [kind, Read.structural(args), Read.structural(options)]
      end

      def eq(value); compare(:eq, value); end
      def not_eq(value); compare(:not_eq, value); end
      def gt(value); compare(:gt, value); end
      def gte(value); compare(:gte, value); end
      def lt(value); compare(:lt, value); end
      def lte(value); compare(:lte, value); end
      def ilike(pattern); compare(:ilike, pattern); end
      def in(values); Node.new(:in, [self, values]); end
      def not_in(values); Node.new(:not_in, [self, values]); end
      def as(name); Node.new(:as, [self, Read.identifier(name)]); end
      def asc; Node.new(:order, [self, :asc]); end
      def desc; Node.new(:order, [self, :desc]); end
      def and(other); Node.new(:and, [self, other]); end
      def or(other); Node.new(:or, [self, other]); end
      def not; Node.new(:not, [self]); end

      def compare(operator, value)
        Node.new(operator, [self, value.is_a?(Node) ? value : Node.new(:value, [value])])
      end
    end
  end

  module SQL
    def self.count(column = nil, distinct: false)
      Read::Node.new(:count, column.nil? ? [] : [column], { distinct: distinct })
    end

    def self.output(name)
      Read::Node.new(:output, [Read.identifier(name)])
    end

    def self.bind(value)
      Read::Node.new(:value, [value])
    end

    def self.raw(parts, dependencies:, type:, nullable:, aggregate: false)
      Read::Node.new(:raw, parts, { dependencies: dependencies, type: type, nullable: nullable, aggregate: aggregate })
    end
  end
end
