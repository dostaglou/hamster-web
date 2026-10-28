# frozen_string_literal: true

module Hamster
  class Relation
    attr_reader :source, :state

    def initialize(source, state = {})
      @source = source
      @state = Read.snapshot({ select: [], explicit: false, joins: [], where: [], group: [],
                              having: [], order: [], distinct: false, limit: nil, offset: nil, page: nil,
                              identity: "anonymous" }.merge(state))
      freeze
    end

    def all; self; end
    def named(identity); change(identity: identity.to_s); end
    def select(*items); change(select: state[:select] + expressions(items), explicit: true); end
    def reselect(*items); change(select: expressions(items), explicit: true); end
    def where(condition); change(where: state[:where] + conditions(condition)); end
    def having(condition); change(having: state[:having] + conditions(condition)); end
    def group(*items); change(group: state[:group] + expressions(items)); end
    def order(*items); change(order: state[:order] + orderings(items)); end
    def reorder(*items); change(order: orderings(items)); end
    def distinct(enabled = true); change(distinct: enabled); end
    def limit(value); change(limit: value); end
    def offset(value); change(offset: value, page: nil); end

    def page(number)
      unless number.is_a?(Integer) && number > 0
        raise Read::ValidationError, "#{state[:identity]}: PAGE: use a positive integer starting at 1"
      end
      change(page: number, offset: nil)
    end

    def joins(other, on:)
      join(other, on, :inner)
    end

    def left_joins(other, on:)
      join(other, on, :left)
    end

    def compile
      Read::Compiler.new(Read::Validator.new(resolve_page).validate).compile
    end

    def to_sql; compile.sql; end
    def binds; compile.binds; end

    def load(connection: nil)
      Instrumentation.instrument("query.load", attributes: {"query.name" => state[:identity]}) do
        compiled = compile
        result = (connection || Record.connection).execute(compiled.sql, compiled.binds)
        Read::Decoder.new(compiled).decode(result)
      end
    end

    def count(connection: nil)
      Instrumentation.instrument("query.count", attributes: {"query.name" => state[:identity]}) do
        compiled = Read::Compiler.new(Read::Validator.new(resolve_page).validate).compile(count: true)
        result = (connection || Record.connection).execute(compiled.sql, compiled.binds)
        rows = Read::Decoder.new(compiled).decode(result)
        raise Read::DecodeError, "Count result must contain exactly one row" unless rows.length == 1
        rows.first[:count]
      end
    end

    # Terminal reads stay lazy until this call and use PostgreSQL for the limit.
    def first(connection: nil)
      return resolve_page.first(connection: connection) unless state[:page].nil?
      compile
      return nil if state[:limit] == 0

      query = self
      if query.state[:order].empty? && implicit_primary_order?
        query = query.order(source[:id].asc)
      end
      query.limit(query.state[:limit].nil? ? 1 : [query.state[:limit], 1].min)
           .load(connection: connection).first
    end

    def last(connection: nil)
      return resolve_page.last(connection: connection) unless state[:page].nil?
      compile
      return nil if state[:limit] == 0

      # Reversing an ordered, offset relation changes which rows the offset skips.
      # Load that already-scoped window to preserve its meaning.
      if !state[:offset].nil? || (state[:order].empty? && !implicit_primary_order?)
        query = state[:order].empty? && implicit_primary_order? ? order(source[:id].asc) : self
        return query.load(connection: connection).last
      end

      if state[:order].empty? && !state[:limit].nil?
        return order(source[:id].asc).load(connection: connection).last
      end

      reversed = if state[:order].empty?
                   order(source[:id].desc)
                 else
                   order = state[:order].map do |item|
                     direction = item.args[1] == :asc ? :desc : :asc
                     Read::Node.new(:order, [item.args[0], direction])
                   end
                   reorder(*order)
                 end
      if reversed.state[:limit].nil?
        reversed.limit(1).load(connection: connection).first
      else
        reversed.load(connection: connection).first
      end
    end

    private

    def validate_page_size!
      unless state[:limit].is_a?(Integer) && state[:limit] > 0
        raise Read::ValidationError, "#{state[:identity]}: PAGE: pagination requires a positive page size; add .limit(size)"
      end
    end

    def resolve_page
      return self if state[:page].nil?
      validate_page_size!
      query = self
      if state[:order].empty?
        unless implicit_primary_order?
          raise Read::ValidationError, "#{state[:identity]}: PAGE: add an explicit order for grouped, distinct, aggregate, or id-less queries"
        end
        query = order(source[:id].asc)
      end
      query.offset((state[:page] - 1) * state[:limit])
    end

    def change(changes)
      Relation.new(source, state.merge(changes))
    end

    def expression(item)
      item.is_a?(Symbol) ? source[item] : item
    end

    def expressions(items)
      items.flatten.map { |item| expression(item) }
    end

    def conditions(condition)
      if condition.is_a?(Hash)
        condition.flat_map do |key, value|
          column = source[key]
          if value.is_a?(Range)
            bounds = []
            bounds << column.gte(value.begin) unless value.begin.nil?
            if !value.end.nil?
              bounds << (value.exclude_end? ? column.lt(value.end) : column.lte(value.end))
            end
            bounds
          elsif value.is_a?(Array)
            [column.in(value)]
          else
            [column.eq(value)]
          end
        end
      else
        [condition]
      end
    end

    def orderings(items)
      items.flatten.flat_map do |item|
        if item.is_a?(Hash)
          item.map { |key, direction| Read::Node.new(:order, [source[key], direction]) }
        else
          node = expression(item)
          [node.is_a?(Read::Node) && node.kind == :order ? node : Read::Node.new(:order, [node, :asc])]
        end
      end
    end

    def implicit_primary_order?
      id = source.columns[:id]
      id && id[:enabled] && state[:group].empty? && state[:having].empty? && !state[:distinct] &&
        !state[:select].any? { |item| aggregate_expression?(item) } &&
        !state[:order].any? { |item| aggregate_expression?(item) }
    end

    def aggregate_expression?(item)
      return false unless item.is_a?(Read::Node)
      return true if item.kind == :count || (item.kind == :raw && item.options[:aggregate])
      item.args.any? { |argument| aggregate_expression?(argument) }
    end

    def join(other, on, kind)
      joined = other.is_a?(Read::Source) ? other : other.all.source
      change(joins: state[:joins] + [Read::Node.new(:join, [joined, on], { kind: kind })])
    end
  end
end
