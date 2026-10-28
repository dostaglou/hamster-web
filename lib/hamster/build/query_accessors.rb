# frozen_string_literal: true

require "ripper"

module Hamster
  # Spinel's macro expander requires every argument to be literal. Query.field's
  # source expression isn't, so emit ordinary getters before AOT compilation.
  module QueryAccessors
    module_function

    def lines(source, declaration: "field", writers: false)
      tree = Ripper.sexp(source)
      raise "Cannot parse Ruby while generating Query getters" unless tree
      getters = {}
      visit(tree, [], getters, declaration)
      getters.flat_map do |path, names|
        ["class #{path}"] + names.uniq.flat_map { |name| ["  def #{name}; self[:#{name}]; end"] + (writers ? ["  def #{name}=(value); write_attribute(:#{name}, value); end"] : []) } + ["end"]
      end
    end

    def constant(node)
      return nil unless node.is_a?(Array)
      case node[0]
      when :@const then node[1]
      when :const_ref, :var_ref then constant(node[1])
      when :top_const_ref then "::#{constant(node[1])}"
      when :const_path_ref, :const_path_field then "#{constant(node[1])}::#{constant(node[2])}"
      end
    end

    def visit(node, scope, getters, declaration)
      return unless node.is_a?(Array)
      if node[0] == :class || node[0] == :module
        name = constant(node[1])
        return unless name
        path = name.start_with?("::") ? name.delete_prefix("::") : (scope + [name]).join("::")
        body = node[node[0] == :class ? 3 : 2]
        visit(body, [path], getters, declaration)
      elsif [:def, :defs].include?(node[0])
        return
      elsif (node[0] == :command && node[1][1] == declaration) ||
            (node[0] == :method_add_arg && node[1][0] == :fcall && node[1][1][1] == declaration)
        args = node[2]
        args = args[1] if args && args[0] == :arg_paren
        first = args[1][0] if args && args[0] == :args_add_block
        literal = first[1][1] if first && first[0] == :symbol_literal && first[1][0] == :symbol
        name = literal[1] if literal && [:"@ident", :"@op", :"@kw"].include?(literal[0])
        if first && first[0] == :string_literal && first[1][0] == :string_content && first[1].length == 2
          name = first[1][1][1] if first[1][1][0] == :@tstring_content
        end
        unless name && name.match?(/\A[a-z_][a-z0-9_]*\z/)
          raise "#{scope.join('::')}: Query field names must be literal accessor names for Spinel"
        end
        unless scope.empty?
          getters[scope.join("::")] ||= []
          getters[scope.join("::")] << name
        end
      else
        node.each { |child| visit(child, scope, getters, declaration) if child.is_a?(Array) }
      end
    end
  end
end

# Standalone scripts and compiled fixtures can use the same static getter pass.
# ruby tools/query_accessors.rb test/spinel_query_smoke.rb > /tmp/query-smoke.rb
if $PROGRAM_NAME == __FILE__
  abort "Usage: ruby tools/query_accessors.rb SOURCE.rb [SOURCE.rb ...]" if ARGV.empty?
  ARGV.each do |path|
    puts "require_relative #{File.expand_path(path).inspect}"
    puts Hamster::QueryAccessors.lines(File.read(path))
  end
end
