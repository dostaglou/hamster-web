# frozen_string_literal: true


module Hamster
  module Read
    class Validator
      attr_reader :relation, :source, :state, :outputs, :dependencies, :table_rows, :result_class

      def initialize(relation)
        @relation = relation
        @source = relation.source
        @state = relation.state.dup
        @outputs = []
        @dependencies = []
        @sources = [source]
        @left_sources = []
        @aliases = {}
      end

      def fail!(message, clause)
        raise ValidationError, "#{state[:identity]}: #{clause}: #{message}"
      end

      def validate
        state[:joins].each do |join|
          other = join.args[0]
          fail!("duplicate source alias #{other.label}", "JOIN") if @sources.any? { |s| s.label == other.label }
          @sources << other
          @left_sources << other.key if join.options[:kind] == :left
        end
        selections = if state[:explicit]
                       state[:select]
                     else
                       source.columns.select { |_key, spec| spec[:enabled] }.map { |key, _spec| source[key] }
                     end
        fail!("empty projection", "SELECT") if selections.empty?
        (state[:declared_fields] || []).each { |node| @aliases[node.args[1]] = node.args[0] }
        declared_aliases = @aliases.dup
        declared_projection = (state[:declared_fields] || []).map do |node|
          resolved = resolve(node, "SELECT", [])
          [output_name(resolved), unwrap(resolved).key]
        end
        selections.each do |node|
          if node.is_a?(Node) && node.kind == :as
            name = node.args[1]
            # Query output references continue to name the declared field even
            # when a runtime projection replaces or aliases that field.
            @aliases[name] = node.args[0] unless declared_aliases.key?(name)
          end
        end
        state[:select] = unique(selections.map do |node|
          resolved = resolve(node, "SELECT", [])
          node.kind == :output ? resolved.as(node.args[0]) : resolved
        end)
        state[:group] = unique(state[:group].map { |node| resolve(node, "GROUP BY", []) })
        [:where, :having, :order].each do |clause|
          state[clause] = state[clause].map { |node| resolve(node, clause.to_s.upcase, []) }
        end
        visible = [source]
        state[:joins] = state[:joins].map do |join|
          visible << join.args[0]
          node = resolve(join.args[1], "ON", [])
          info = inspect_node(node, "ON", visible)
          predicate!(info, "ON")
          Node.new(:join, [join.args[0], node], join.options)
        end
        state[:select].each do |node|
          info = inspect_node(node, "SELECT", @sources)
          name = output_name(node)
          fail!("projection needs an explicit alias", "SELECT") unless name
          fail!("conflicting output #{name}", "SELECT") if outputs.any? { |out| out[:name] == name }
          outputs << { name: name, type: info[:type], nullable: info[:nullable], expression: unwrap(node) }.freeze
        end
        [:where, :having].each do |clause|
          state[clause].each { |node| predicate!(inspect_node(node, clause.to_s.upcase, @sources), clause.to_s.upcase) }
        end
        state[:group].each { |node| inspect_node(node, "GROUP BY", @sources) }
        state[:order].each do |node|
          fail!("unsupported ordering", "ORDER BY") unless node.is_a?(Node) && node.kind == :order
          fail!("direction must be :asc or :desc", "ORDER BY") unless [:asc, :desc].include?(node.args[1])
          inspect_node(node.args[0], "ORDER BY", @sources)
        end
        grouped = !state[:group].empty? || !state[:having].empty? ||
                  state[:select].any? { |node| aggregate?(node) } || state[:order].any? { |node| aggregate?(node.args[0]) }
        if grouped
          state[:select].each { |node| check_group(unwrap(node), "SELECT") }
          state[:having].each { |node| check_group(node, "HAVING") }
          state[:order].each { |node| check_group(node.args[0], "ORDER BY") }
        end
        fail!("distinct must be boolean", "DISTINCT") unless [true, false].include?(state[:distinct])
        if state[:distinct]
          state[:order].each do |node|
            unless outputs.any? { |out| out[:expression].key == node.args[0].key }
              fail!("DISTINCT ordering must be selected", "ORDER BY")
            end
          end
        end
        [:limit, :offset].each do |clause|
          value = state[clause]
          unless value.nil? || (value.is_a?(Integer) && value >= 0)
            fail!("must be a nonnegative integer", clause.to_s.upcase)
          end
        end
        @table_rows = state[:joins].empty? && !grouped && state[:select].all? do |node|
          node.kind == :column && node.args[0].key == source.key
        end
        if state[:result_class]
          @result_class = state[:result_class] if outputs.all? do |out|
            declared_projection.include?([out[:name], out[:expression].key])
          end
          @table_rows = false
        end
        @state = Read.snapshot(state)
        @outputs.freeze
        @dependencies.freeze
        self
      end

      def resolve(node, clause, stack)
        fail!("unsupported expression #{node.class}", clause) unless node.is_a?(Node)
        if node.kind == :output
          name = node.args[0]
          fail!("unknown output #{name}", clause) unless @aliases.key?(name)
          fail!("cyclic output #{name}", clause) if stack.include?(name)
          return resolve(@aliases[name], clause, stack + [name])
        end
        args = node.args.map { |arg| arg.is_a?(Node) ? resolve(arg, clause, stack) : arg }
        Node.new(node.kind, args, node.options)
      end

      def unique(nodes)
        result = []
        nodes.each { |node| result << node unless result.any? { |old| old.key == node.key } }
        result
      end

      def unwrap(node)
        node.kind == :as ? node.args[0] : node
      end

      def output_name(node)
        return node.args[1] if node.kind == :as
        return node.args[1].to_s if node.kind == :column
        return "count" if node.kind == :count
        nil
      end

      def info(type, nullable, aggregate = false)
        { type: type, nullable: nullable, aggregate: aggregate }
      end

      def predicate!(metadata, clause)
        fail!("condition must be boolean", clause) unless metadata[:type] == :boolean
      end

      def inspect_node(node, clause, visible)
        fail!("unsupported expression", clause) unless node.is_a?(Node)
        case node.kind
        when :column
          table, name = node.args
          fail!("source #{table.label} is not visible", clause) unless visible.any? { |s| s.key == table.key }
          definition = table.columns[name]
          fail!("#{table.schema}.#{table.name}.#{name} is undeclared", clause) unless definition
          fail!("#{table.schema}.#{table.name}.#{name} is disabled", clause) unless definition[:enabled]
          dependency = { schema: table.schema, table: table.name, source: table.label, column: name, clause: clause }.freeze
          @dependencies << dependency unless @dependencies.include?(dependency)
          info(definition[:type], definition[:nullable] || @left_sources.include?(table.key))
        when :as
          fail!("projection aliases are only allowed in SELECT", clause) unless clause == "SELECT"
          inspect_node(node.args[0], clause, visible)
        when :value
          value = node.args[0]
          type = case value
                 when NilClass then :null
                 when Integer then :bigint
                 when String then :text
                 when TrueClass, FalseClass then :boolean
                 when Time then :timestamptz
                 else
                   case value.class.to_s
                   when "DateTime" then :timestamptz
                   when "Date" then :date
                   else fail!("unsupported bound value #{value.class}", clause)
                   end
                 end
          info(type, value.nil?)
        when :count
          fail!("aggregate is not allowed", clause) if ["WHERE", "ON", "GROUP BY"].include?(clause)
          fail!("COUNT DISTINCT requires a column", clause) if node.args.empty? && node.options[:distinct]
          fail!("COUNT distinct flag must be boolean", clause) unless [true, false].include?(node.options[:distinct])
          node.args.each do |arg|
            fail!("nested aggregate", clause) if aggregate?(arg)
            inspect_node(arg, clause, visible)
          end
          info(:bigint, false, true)
        when :raw
          type = node.options[:type]
          fail!("unsupported raw type", clause) unless TYPES.key?(type)
          [:nullable, :aggregate].each do |flag|
            fail!("raw #{flag} must be boolean", clause) unless [true, false].include?(node.options[flag])
          end
          if node.options[:aggregate] && ["WHERE", "ON", "GROUP BY"].include?(clause)
            fail!("aggregate is not allowed", clause)
          end
          deps = node.options[:dependencies]
          fail!("raw dependencies must be an array of columns", clause) unless deps.is_a?(Array)
          deps.each do |dep|
            fail!("raw dependency must be a column", clause) unless dep.is_a?(Node) && dep.kind == :column
            inspect_node(dep, clause, visible)
          end
          fail!("raw parts cannot be empty", clause) if node.args.empty?
          node.args.each do |part|
            unless part.is_a?(String) || (part.is_a?(Node) && part.kind == :value)
              fail!("raw parts must be strings or SQL.bind nodes", clause)
            end
            inspect_node(part, clause, visible) if part.is_a?(Node)
          end
          info(type, node.options[:nullable], node.options[:aggregate])
        when :eq, :not_eq, :gt, :gte, :lt, :lte
          left = inspect_node(node.args[0], clause, visible)
          right = inspect_node(node.args[1], clause, visible)
          if right[:type] == :null && ![:eq, :not_eq].include?(node.kind)
            fail!("NULL only supports eq and not_eq", clause)
          end
          compatible!(left, right, node.args[1], clause)
          info(:boolean, right[:type] == :null ? false : left[:nullable] || right[:nullable])
        when :ilike
          left = inspect_node(node.args[0], clause, visible)
          right = inspect_node(node.args[1], clause, visible)
          fail!("ILIKE requires text operands", clause) unless left[:type] == :text && right[:type] == :text
          info(:boolean, left[:nullable] || right[:nullable])
        when :in, :not_in
          left = inspect_node(node.args[0], clause, visible)
          values = node.args[1]
          fail!("membership requires an array", clause) unless values.is_a?(Array)
          values.each do |value|
            rhs = Node.new(:value, [value])
            compatible!(left, inspect_node(rhs, clause, visible), rhs, clause)
          end
          info(:boolean, left[:nullable])
        when :and, :or, :not
          node.args.each { |arg| predicate!(inspect_node(arg, clause, visible), clause) }
          info(:boolean, true)
        else
          fail!("unsupported expression #{node.kind}", clause)
        end
      end

      def compatible!(left, right, rhs, clause)
        return if right[:type] == :null || left[:type] == right[:type]
        return if [:integer, :bigint].include?(left[:type]) && [:integer, :bigint].include?(right[:type])
        # Bound text is passed with an unspecified PostgreSQL type, allowing e.g. an ID from a route.
        return if rhs.kind == :value && right[:type] == :text
        return if right[:type] == :date && left[:type] == :timestamptz
        fail!("incompatible comparison types", clause)
      end

      def aggregate?(node)
        return false unless node.is_a?(Node)
        return true if node.kind == :count || (node.kind == :raw && node.options[:aggregate])
        node.args.any? { |arg| arg.is_a?(Node) && aggregate?(arg) }
      end

      def check_group(node, clause)
        return if state[:group].any? { |group| group.key == node.key }
        return if node.kind == :count || node.kind == :value
        return if node.kind == :raw && node.options[:aggregate]
        fail!("nonaggregate expression must be explicitly grouped", clause) if [:column, :raw].include?(node.kind)
        node.args.each { |arg| check_group(arg, clause) if arg.is_a?(Node) }
      end
    end
  end
end
