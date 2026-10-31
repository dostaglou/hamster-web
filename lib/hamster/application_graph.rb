# frozen_string_literal: true
require "ripper"
require "json"
require_relative "build/manifest"

module Hamster
  class ApplicationGraph
    UNKNOWN = Object.new.freeze
    attr_reader :root, :nodes, :edges, :diagnostics
    def initialize(root)
      @root = File.realpath(root)
      @nodes, @edges, @diagnostics, @definitions, @references = {}, [], [], {}, []
    end
    def token(node)
      return nil unless node.is_a?(Array)
      return node if node[0].to_s.start_with?("@")
      node.each { |child| found = token(child); return found if found }
      nil
    end
    def line(node); token(node)&.dig(2, 0) || 1; end
    def constant(node); Build::Callbacks.constant(node); end
    def literal(node)
      return UNKNOWN unless node.is_a?(Array)
      case node[0]
      when :string_literal
        content = node[1]
        return "" if content == [:string_content]
        return content[1][1] if content[0] == :string_content && content.length == 2 && content[1][0] == :@tstring_content
      when :symbol_literal
        return node.dig(1, 1, 1) if node.dig(1, 0) == :symbol
      when :var_ref
        return true if node.dig(1, 1) == "true"
        return false if node.dig(1, 1) == "false"
        return nil if node.dig(1, 1) == "nil"
      when :@int then return node[1].to_i
      end
      UNKNOWN
    end
    def known(node)
      value = literal(node)
      value == UNKNOWN ? "unknown" : value
    end
    def column_node(owner, column, seen = [])
      return nil if seen.include?(owner)
      id = "column:#{owner}:#{column}"
      return id if nodes.key?(id)
      parent = resolve(@definitions[owner]&.fetch(:parent), owner.split("::")[0...-1].join("::"))
      parent ? column_node(parent, column, seen + [owner]) : nil
    end
    def table_attributes(owner, seen = [])
      return {} if seen.include?(owner)
      parent = resolve(@definitions[owner]&.fetch(:parent), owner.split("::")[0...-1].join("::"))
      inherited = parent ? table_attributes(parent, seen + [owner]) : {}
      inherited.merge(nodes["class:#{owner}"]["attributes"])
    end
    def arguments(node)
      return [] unless node
      node = node[1] if node[0] == :arg_paren
      node && node[0] == :args_add_block ? node[1] : []
    end
    def invocation(node)
      return nil unless node.is_a?(Array)
      case node[0]
      when :command then return [node[1][1], arguments(node[2])]
      when :method_add_arg
        target = node[1]
        return [target[1][1], arguments(node[2])] if target[0] == :fcall
      end
      nil
    end
    def keywords(args)
      hash = args.find { |a| a.is_a?(Array) && a[0] == :bare_assoc_hash }
      (hash ? hash[1] : []).each_with_object({}) do |pair, result|
        result[pair[1][1].delete_suffix(":")] = pair[2] if pair[0] == :assoc_new && pair[1][0] == :@label
      end
    end
    def add(id, kind, name, path, at, attributes = {})
      @nodes[id] ||= {"id" => id, "kind" => kind, "name" => name, "path" => path, "line" => at, "attributes" => attributes}
    end
    def edge(from, to, relation, certainty = "declared")
      value = {"from" => from, "to" => to, "relation" => relation, "certainty" => certainty}
      edges << value unless edges.include?(value)
    end
    def diagnostic(code, message, path, at, severity = "error")
      value = {"code" => code, "message" => message, "path" => path, "line" => at, "severity" => severity}
      diagnostics << value unless diagnostics.include?(value)
    end
    def resolve(reference, owner)
      return nil unless reference
      parts = owner.to_s.split("::")
      parts.length.downto(0).map { |n| (parts.take(n) + [reference]).join("::") }.find { |candidate| @definitions.key?(candidate) }
    end
    def walk(node, owner, path)
      return unless node.is_a?(Array)
      if [:class, :module].include?(node[0])
        local = constant(node[1])
        return diagnostic("inspect.dynamic_class", "Dynamic declaration cannot be resolved", path, line(node), "info") unless local
        name = local.include?("::") ? local : [owner, local].reject(&:empty?).join("::")
        parent = node[0] == :class ? constant(node[2]) : nil
        @definitions[name] ||= {parent: parent, node: node}
        add("class:#{name}", node[0] == :module ? "concern" : "class", name, path, line(node[1]), {"parent" => parent})
        walk(node[node[0] == :class ? 3 : 2], name, path)
        return
      elsif node[0] == :def
        name = node[1][1]
        add("method:#{owner}##{name}", "method", "#{owner}##{name}", path, line(node[1]))
        edge("class:#{owner}", "method:#{owner}##{name}", "defines")
      elsif node[0] == :aref && (reference = constant(node[1]))
        args = arguments(node[2])
        column = literal(args.first)
        @references << [owner, reference, column, path, line(node)] if column != UNKNOWN
      end
      if (call = invocation(node))
        method, args = call
        options = keywords(args)
        id = "class:#{owner}"
        case method
        when "table"
          name = literal(args.first)
          if name != UNKNOWN && nodes[id]
            nodes[id]["attributes"].merge!("table" => name, "schema" => options["schema"] ? known(options["schema"]) : "public", "enabled" => options["enabled"] ? known(options["enabled"]) : true)
          end
        when "column"
          name = literal(args.first)
          if name != UNKNOWN
            attrs = options.to_h { |key, value| [key, literal(value) == UNKNOWN ? "unknown" : literal(value)] }
            attrs["enabled"] = true unless attrs.key?("enabled")
            add("column:#{owner}:#{name}", "column", name, path, line(node), attrs)
            edge(id, "column:#{owner}:#{name}", "declares")
          end
        when "include", "from", "model"
          reference = constant(args.first)
          @references << [owner, reference, nil, path, line(node), method == "include" ? "includes" : (method == "model" ? "uses_model" : "from")] if reference
        when "before_action", "after_action"
          args.each do |arg|
            target = literal(arg)
            next if target == UNKNOWN
            @references << [owner, target, nil, path, line(node), method]
          end
        when "get", "head", "post", "patch", "delete"
          pattern, action = literal(args.first), constant(options["to"])
          if pattern != UNKNOWN && action
            route = "route:#{method.upcase}:#{pattern}"
            diagnostic("route.duplicate", "Duplicate route #{method.upcase} #{pattern}", path, line(node)) if nodes.key?(route)
            add(route, "route", "#{method.upcase} #{pattern}", path, line(node), {"method" => method.upcase, "pattern" => pattern, "name" => literal(options["as"]) == UNKNOWN ? nil : literal(options["as"])})
            @references << [owner, action, nil, path, line(node), "routes_to", route]
          end
        when "respond"
          if options["view"]
            view = literal(options["view"])
            if view == UNKNOWN
              diagnostic("view.dynamic_reference", "View dependency is unknown", path, line(node), "info")
              unknown = "unknown:view:#{path}:#{line(node)}"
              add(unknown, "unknown", "dynamic view", path, line(node))
              edge(id, unknown, "renders", "unknown")
            else
              edge(id, "view:#{view}", "renders")
              @references << [owner, view, nil, path, line(node), "view"]
            end
          end
        end
      end
      node.each { |child| walk(child, owner, path) if child.is_a?(Array) }
    end
    def kind(name, seen = [])
      return "class" if seen.include?(name)
      parent = @definitions[name]&.fetch(:parent)
      return "action" if parent == "Hamster::Action::Base"
      return "table" if parent == "Hamster::Table"
      return "query" if parent == "Hamster::Query"
      return "form" if parent == "Hamster::Form"
      return "job" if parent == "Hamster::Job"
      resolved = resolve(parent, name.split("::")[0...-1].join("::"))
      resolved ? kind(resolved, seen + [name]) : nodes["class:#{name}"]["kind"]
    end
    def method_owner(owner, target, seen = [])
      return nil if seen.include?(owner)
      return owner if nodes.key?("method:#{owner}##{target}")
      seen += [owner]
      includes = @references.select { |o, _, _, _, _, relation| o == owner && relation == "includes" }.map { |_, ref| resolve(ref, owner) }.compact
      parent = resolve(@definitions[owner]&.fetch(:parent), owner.split("::")[0...-1].join("::"))
      (includes + [parent].compact).each do |candidate|
        result = method_owner(candidate, target, seen)
        return result if result
      end
      nil
    end
    def build
      sources = {}
      Dir.glob("{app,db,test}/**/*.rb", base: root).sort.reject { |path| path.start_with?("db/migrations/") }.each do |path|
        source = File.read(File.join(root, path))
        sources[path] = source unless path.start_with?("test/")
        tree = Ripper.sexp(source)
        tree ? walk(tree, "", path) : diagnostic("ruby.syntax", "Invalid Ruby syntax", path, 1)
        if path.start_with?("test/")
          add("test:#{path}", "test", path, path, 1)
          if (location = path[%r{\Atest/requests/(.+)_test.rb\z}, 1])
            action = nodes.values.find { |n| n["path"] == "app/routes/#{location}/action.rb" && n["attributes"]["parent"] }
            edge("test:#{path}", action["id"], "tests", "inferred") if action
          end
        end
      end
      @definitions.each_key { |name| nodes["class:#{name}"]["kind"] = kind(name) }
      Build::Jobs.declarations(sources.values.map { |source| Ripper.sexp(source) }).each do |owner, name, versions|
        nodes["class:#{owner}"]["attributes"].merge!("job_name" => name, "accepted_versions" => versions) if nodes["class:#{owner}"]
      end
      @definitions.each_key do |name|
        node = nodes["class:#{name}"]
        node["attributes"] = table_attributes(name) if node["kind"] == "table"
      end
      Dir.glob("{app/routes,app/views}/**/*.html.erb", base: root).sort.each do |path|
        name = path.sub(%r{\Aapp/(?:routes|views)/}, "").sub(%r{/view\.html\.erb\z}, "").delete_suffix(".html.erb")
        add("view:#{name}", "view", name, path, 1)
        File.readlines(File.join(root, path)).each_with_index do |source, index|
          source.scan(/<%=\s*render\s*(?:\(\s*)?["']([^"']+)["']/).flatten.each { |view| edge("view:#{name}", "view:#{view}", "renders"); @references << [name, view, nil, path, index + 1, "view"] }
        end
      end
      asset_outputs = Build::Assets.outputs(root)
      asset_paths = JSON.parse(asset_outputs.fetch("public/assets/manifest.json")).fetch("assets")
      asset_paths.each do |name, fingerprint|
        add("asset:#{name}", "asset", name, "app/assets/#{name}", 1, {"url" => fingerprint})
      end
      nodes.values.select { |n| n["kind"] == "view" }.each do |view|
        File.read(File.join(root, view["path"])).scan(/Hamster::Assets.path\(["']([^"']+)["']\)/).flatten.each do |name|
          edge(view["id"], "asset:#{name}", "uses_asset")
          diagnostic("asset.missing", "Missing asset #{name}", view["path"], 1) unless asset_paths.key?(name)
        end
      end
      @references.each do |owner, reference, column, path, at, relation, origin|
        relation ||= "references"
        if relation == "view"
          diagnostic("view.missing", "Missing view #{reference}", path, at) unless nodes.key?("view:#{reference}")
        elsif %w[before_action after_action].include?(relation)
          target_owner = method_owner(owner, reference)
          if target_owner
            edge("class:#{owner}", "method:#{target_owner}##{reference}", relation)
          else
            diagnostic("callback.unresolved", "Unresolved callback #{owner}##{reference}", path, at)
          end
        else
          target = resolve(reference, owner)
          if target
            edge(origin || "class:#{owner}", "class:#{target}", relation)
            table = nodes["class:#{target}"]
            if column
              column_id = column_node(target, column) || "column:#{target}:#{column}"
              edge("class:#{owner}", column_id, "references")
              if nodes[column_id] && nodes[column_id]["attributes"]["enabled"] == false
                diagnostic("schema.disabled_column", "Reference to disabled #{target}.#{column}", path, at)
              end
            end
            if table["attributes"]["enabled"] == false && relation != "includes"
              diagnostic("schema.disabled_table", "Reference to disabled table #{target}", path, at)
            end
          else
            unknown = "unknown:#{reference}"
            add(unknown, "unknown", reference, path, at)
            edge(origin || "class:#{owner}", unknown, relation, "unknown")
            severity = relation == "routes_to" ? "error" : "info"
            diagnostic("reference.unresolved", "Unresolved #{relation} #{reference}", path, at, severity)
          end
        end
      end
      @definitions.each do |name, definition|
        parent = resolve(definition[:parent], name.split("::")[0...-1].join("::"))
        edge("class:#{name}", "class:#{parent}", "inherits") if parent
      end
      begin
        Build::Callbacks.compile(sources.values)
        Build::Manifest.outputs(root)
      rescue StandardError => error
        diagnostic("declaration.invalid", error.message, nil, nil)
      end
      self
    end
    def report(scope = nil, target = nil)
      chosen = nodes.values
      if scope == "routes"
        ids = chosen.select { |n| n["kind"] == "route" }.map { |n| n["id"] }
        chosen = chosen.select { |n| ids.include?(n["id"]) || edges.any? { |e| ids.include?(e["from"]) && e["to"] == n["id"] } }
      elsif scope == "action"
        action = chosen.find { |n| n["kind"] == "action" && (n["name"] == target || n["path"] == "app/routes/#{target}/action.rb") }
        raise ArgumentError, "Unknown action #{target}" unless action
        ids = [action["id"]]
        loop do
          connected = edges.select { |e| ids.include?(e["from"]) || (e["to"] == action["id"] && %w[routes_to tests].include?(e["relation"])) }
          expanded = (ids + connected.flat_map { |e| [e["from"], e["to"]] }).uniq
          break if expanded == ids
          ids = expanded
        end
        chosen = chosen.select { |n| ids.include?(n["id"]) }
      end
      ids = chosen.map { |n| n["id"] }
      {"format_version" => 1, "valid" => diagnostics.none? { |d| d["severity"] == "error" },
       "nodes" => chosen.sort_by { |n| n["id"] }, "edges" => edges.select { |e| ids.include?(e["from"]) && ids.include?(e["to"]) }.sort_by { |e| [e["from"], e["relation"], e["to"]] },
       "diagnostics" => diagnostics.sort_by { |d| [d["path"].to_s, d["line"].to_i, d["code"], d["message"]] }}
    end
    def self.cli(root, arguments)
      args = arguments.dup
      json = !!args.delete("--json")
      check = !!args.delete("--check")
      scope = args.shift
      target = args.shift if scope == "action"
      raise ArgumentError, "Usage: inspect [routes | action resource/action] [--check] [--json]" unless args.empty? && [nil, "routes", "action"].include?(scope) && (scope != "action" || target)
      report = new(root).build.report(scope, target)
      if json
        puts JSON.generate(report)
      else
        report["nodes"].each { |n| puts "#{n['kind']} #{n['name']} #{n['path']}:#{n['line']}" }
        report["diagnostics"].each { |d| puts "#{d['code']}: #{d['message']}" }
      end
      check && !report["valid"] ? 1 : 0
    end
  end
end
