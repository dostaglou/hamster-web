# frozen_string_literal: true

module Hamster
  # Named read-only projections; all execution remains in Relation.
  class Query < KeyedRow
    REGISTRY = []

    def self.inherited(child)
      child.set_definition(@base_source, fields, clauses)
      REGISTRY << child
    end

    def self.registry
      REGISTRY.dup.freeze
    end

    def self.validate_all!
      registry.each { |query| query.all.compile }
    end

    def self.set_definition(source, definitions, operations)
      @base_source = source
      @fields = definitions.dup
      @local_fields = []
      @clauses = operations.dup
    end

    def self.fields
      Read.snapshot(@fields || {})
    end

    def self.clauses
      Read.snapshot(@clauses || [])
    end

    def self.from(source)
      @base_source = source.all.source
    end

    def self.field(name, source:)
      register_field(name, source)
      # Spinel cannot expand a macro with a nonliteral source: expression.
      # The manifest emits the equivalent static getters for compilation.
      define_method("#{name}") { self[name] } if RUBY_ENGINE == "ruby"
    end

    def self.register_field(name, source)
      key = Read.identifier(name).to_sym
      unless key.to_s.match?(/\A[a-z_][a-z0-9_]*\z/)
        raise Read::ValidationError, "#{self.name}: SELECT: field #{key} cannot be used as a result accessor"
      end
      if Query.method_defined?(key) || Query.private_method_defined?(key)
        raise Read::ValidationError, "#{self.name}: SELECT: field #{key} would shadow a result method"
      end
      @local_fields ||= []
      if @local_fields.include?(key)
        raise Read::ValidationError, "#{self.name}: SELECT: duplicate field #{key}"
      end
      unless source.is_a?(Read::Node)
        raise Read::ValidationError, "#{self.name}: SELECT: field #{key} source must be a SQL expression"
      end
      @local_fields = @local_fields + [key]
      @fields = fields.merge(key => source)
    end

    def self.output(name); SQL.output(name); end

    def self.add_clause(kind, args)
      @clauses = clauses + [Read.snapshot([kind, args])]
    end

    def self.joins(source, on:); add_clause(:joins, [source, on]); end
    def self.left_joins(source, on:); add_clause(:left_joins, [source, on]); end
    def self.where(condition); add_clause(:where, [condition]); end
    def self.group(*items); add_clause(:group, items); end
    def self.having(condition); add_clause(:having, [condition]); end
    def self.order(*items); add_clause(:order, items); end
    def self.reorder(*items); add_clause(:reorder, items); end
    def self.distinct(enabled = true); add_clause(:distinct, [enabled]); end
    def self.limit(value); add_clause(:limit, [value]); end
    def self.offset(value); add_clause(:offset, [value]); end

    def self.all
      raise Read::ValidationError, "#{name}: FROM: declare a base source with from" unless @base_source
      raise Read::ValidationError, "#{name}: SELECT: declare at least one field" if fields.empty?
      projection = fields.map { |key, expression| expression.as(key) }
      relation = Relation.new(@base_source, { identity: name, select: projection, explicit: true,
                                            result_class: self, declared_fields: projection })
      clauses.each do |kind, args|
        relation = case kind
                   when :joins then relation.joins(args[0], on: args[1])
                   when :left_joins then relation.left_joins(args[0], on: args[1])
                   when :where then relation.where(args[0])
                   when :group then relation.group(*args)
                   when :having then relation.having(args[0])
                   when :order then relation.order(*args)
                   when :reorder then relation.reorder(*args)
                   when :distinct then relation.distinct(args[0])
                   when :limit then relation.limit(args[0])
                   when :offset then relation.offset(args[0])
                   end
      end
      relation
    end
  end
end
