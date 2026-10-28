# frozen_string_literal: true

module Hamster
  module Read
    class Compiled
      attr_reader :sql, :binds, :dependencies, :outputs, :row_class, :table_rows, :result_class
      def initialize(sql, binds, validated, count: false)
        @sql = sql.freeze
        @binds = Read.snapshot(binds)
        @dependencies = validated.dependencies
        @outputs = count ? Read.snapshot([{ name: "count", type: :bigint, nullable: false }]) : validated.outputs
        @row_class = validated.source.row_class
        @result_class = count ? nil : validated.result_class
        @table_rows = count ? false : validated.table_rows
        freeze
      end
    end

    class Compiler
      def initialize(validated)
        @validated = validated
        @binds = []
      end

      def compile(count: false)
        state = @validated.state
        sql = state[:distinct] ? "SELECT DISTINCT " : "SELECT "
        sql += state[:select].map { |node| expression(node) }.join(", ")
        sql += " FROM #{source_sql(@validated.source)}"
        state[:joins].each do |join|
          kind = join.options[:kind] == :left ? "LEFT JOIN" : "INNER JOIN"
          sql += " #{kind} #{source_sql(join.args[0])} ON #{expression(join.args[1])}"
        end
        sql += " WHERE " + state[:where].map { |node| expression(node) }.join(" AND ") unless state[:where].empty?
        sql += " GROUP BY " + state[:group].map { |node| expression(node) }.join(", ") unless state[:group].empty?
        sql += " HAVING " + state[:having].map { |node| expression(node) }.join(" AND ") unless state[:having].empty?
        unless state[:order].empty?
          sql += " ORDER BY " + state[:order].map { |node| "#{expression(node.args[0])} #{node.args[1].to_s.upcase}" }.join(", ")
        end
        sql += " LIMIT #{bind(state[:limit])}" unless state[:limit].nil?
        sql += " OFFSET #{bind(state[:offset])}" unless state[:offset].nil?
        sql = "SELECT COUNT(*) AS count FROM (#{sql}) AS hamster_count" if count
        Compiled.new(sql, @binds, @validated, count: count)
      end

      def quote(name)
        '"' + name.to_s.gsub('"', '""') + '"'
      end

      def source_sql(source)
        "#{quote(source.schema)}.#{quote(source.name)} AS #{quote(source.label)}"
      end

      def bind(value)
        @binds << value
        "$#{@binds.length}"
      end

      def expression(node)
        case node.kind
        when :column then "#{quote(node.args[0].label)}.#{quote(node.args[1])}"
        when :value then bind(node.args[0])
        when :as then "#{expression(node.args[0])} AS #{quote(node.args[1])}"
        when :count
          inner = node.args.empty? ? "*" : expression(node.args[0])
          "COUNT(#{node.options[:distinct] ? 'DISTINCT ' : ''}#{inner})"
        when :raw
          "(" + node.args.map { |part| part.is_a?(String) ? part : bind(part.args[0]) }.join + ")"
        when :and, :or
          "(#{expression(node.args[0])} #{node.kind.to_s.upcase} #{expression(node.args[1])})"
        when :not then "(NOT #{expression(node.args[0])})"
        when :eq, :not_eq, :gt, :gte, :lt, :lte
          left = expression(node.args[0])
          right = node.args[1]
          if right.kind == :value && right.args[0].nil?
            "(#{left} IS #{node.kind == :not_eq ? 'NOT ' : ''}NULL)"
          else
            operator = { eq: "=", not_eq: "<>", gt: ">", gte: ">=", lt: "<", lte: "<=" }[node.kind]
            "(#{left} #{operator} #{expression(right)})"
          end
        when :ilike
          "(#{expression(node.args[0])} ILIKE #{expression(node.args[1])})"
        when :in, :not_in
          values = node.args[1]
          return node.kind == :in ? "FALSE" : "TRUE" if values.empty?
          non_null = values.reject { |value| value.nil? }
          negative = node.kind == :not_in
          pieces = []
          unless non_null.empty?
            left = expression(node.args[0])
            pieces << "#{left} #{negative ? 'NOT IN' : 'IN'} (#{non_null.map { |value| bind(value) }.join(', ')})"
          end
          pieces << "#{expression(node.args[0])} IS #{negative ? 'NOT ' : ''}NULL" if values.include?(nil)
          "(" + pieces.join(negative ? " AND " : " OR ") + ")"
        else
          raise ValidationError, "Unsupported compiled expression #{node.kind}"
        end
      end
    end
  end
end
