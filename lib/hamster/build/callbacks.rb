# frozen_string_literal: true
require "ripper"

module Hamster
  module Build
    module Callbacks
      module_function

      def constant(node)
        return nil unless node.is_a?(Array)
        case node[0]
        when :@const then node[1]
        when :const_ref, :var_ref, :top_const_ref then constant(node[1])
        when :const_path_ref then [constant(node[1]), constant(node[2])].join("::")
        end
      end

      def compile(sources)
        definitions = {}
        sources.each { |source| scan(Ripper.sexp(source), "", definitions) }
        resolve = lambda do |name, owner|
          parts = owner.split("::")[0...-1]
          candidates = parts.size.downto(0).map { |n| (parts.take(n) + [name]).join("::") }
          candidates.find { |candidate| definitions.key?(candidate) } || name
        end
        collect = nil
        collect = lambda do |name, seen|
          return [[], [], [], false] if seen.include?(name)
          return [[], [], [], true] if name == "Hamster::Action::Base"
          d = definitions[name]
          return [[], [], [], false] unless d
          seen << name
          before, after, methods, action = d[:parent] ? collect.call(resolve.call(d[:parent], name), seen) : [[], [], [], false]
          d[:includes].each do |inc|
            resolved = resolve.call(inc, name)
            raise ArgumentError, "unresolved concern #{inc} in #{name}" unless definitions.key?(resolved)
            b, a, m, = collect.call(resolved, seen)
            before += b; after += a; methods += m
          end
          [before + d[:before], after + d[:after], methods + d[:methods], action]
        end
        definitions.keys.sort.filter_map do |name|
          before, after, methods, action = collect.call(name, [])
          next unless action
          (before + after).each do |target|
            raise ArgumentError, "unresolved callback #{name}##{target}" unless methods.include?(target)
          end
          lines = ["class #{name}", "  def run_before_actions"]
          before.each { |target| lines += ["    result = #{target}", "    return callback_response(result) unless result.nil?"] }
          lines += ["    nil", "  end", "  def run_after_actions(response)"]
          after.each { |target| lines += ["    replacement = #{target}(response)", "    response = callback_response(replacement) unless replacement.nil?"] }
          lines += ["    response", "  end", "end"]
          lines.join("\n")
        end.join("\n") + "\n"
      end

      def scan(node, namespace, definitions)
        return unless node.is_a?(Array)
        if [:module, :class].include?(node[0])
          local = constant(node[1])
          raise ArgumentError, "dynamic class/module declaration" unless local
          name = local.include?("::") ? local : [namespace, local].reject(&:empty?).join("::")
          body = node[node[0] == :class ? 3 : 2]
          d = definitions[name] ||= {parent: nil, includes: [], before: [], after: [], methods: []}
          d[:parent] = constant(node[2]) if node[0] == :class && node[2]
          statements = body[1] || []
          statements.each do |statement|
            next unless statement.is_a?(Array)
            d[:methods] << statement[1][1] if statement[0] == :def
            command = statement
            if statement[0] == :method_add_arg && statement[1][0] == :fcall
              command = [:command, statement[1][1], statement[2][1]]
            end
            if command[0] == :command && %w[before_action after_action include].include?(command[1][1])
              kind = command[1][1]
              args = command[2]
              raise ArgumentError, "#{name}: static #{kind} arguments required" unless args && args[0] == :args_add_block && args[2] == false
              args[1].each do |arg|
                if kind == "include"
                  value = constant(arg)
                  raise ArgumentError, "#{name}: literal concern constant required" unless value
                  d[:includes] << value
                else
                  value = arg.dig(1, 1, 1) if arg[0] == :symbol_literal && arg.dig(1, 0) == :symbol
                  raise ArgumentError, "#{name}: literal callback symbol required" unless value.is_a?(String) && value.match?(/\A[a-z_][a-z0-9_]*[!?]?\z/)
                  d[kind == "before_action" ? :before : :after] << value
                end
              end
            end
            scan(statement, name, definitions) if [:module, :class].include?(statement[0])
          end
        else
          node.each { |child| scan(child, namespace, definitions) if child.is_a?(Array) }
        end
      end
    end
  end
end
