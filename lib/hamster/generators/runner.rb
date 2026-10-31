# frozen_string_literal: true
require "optparse"
require "json"
require_relative "plan"
require_relative "../data"

module Hamster
  module Generators
    module Runner
      module_function
      KINDS = %w[endpoint action view route table migration component form stimulus].freeze
      METHODS = %w[GET HEAD POST PATCH DELETE].freeze
      NAME = /\A[a-z][a-z0-9_]*(?:\/[a-z][a-z0-9_]*)*\z/
      CONSTANT = /\A[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*\z/
      def schema
        options = {"--dry-run" => "boolean", "--json" => "boolean", "--method" => METHODS,
                   "--path" => "absolute route path", "--name" => "route name", "--[no-]view" => "boolean",
                   "--before" => "existing callback; repeatable", "--concern" => "existing concern; repeatable",
                   "--to" => "route action constant", "--timestamp" => "14 digit migration version"}
        {"format_version" => 1, "generators" => KINDS.to_h { |kind| [kind, {"arguments" => ["name", "[column:type ...] (table only)"], "options" => options}] }}
      end

      def camel(name)
        name.split("/").map { |part| part.split("_").map(&:capitalize).join }.join("::")
      end

      def run(root, arguments)
        return puts(JSON.generate(schema)) if arguments == ["--schema"]
        if arguments.empty? || arguments.include?("--help")
          puts "Usage: bin/hamster generate {#{KINDS.join('|')}} name [column:type ...] [--method GET] [--path /path] [--name route_name] [--[no-]view] [--to Action] [--before method] [--concern Module] [--timestamp VERSION] [--dry-run] [--json]"
          return
        end
        args = arguments.dup
        kind, location = args.shift, args.shift
        raise ArgumentError, "Unknown generator; run bin/hamster generate --help" unless KINDS.include?(kind)
        raise ArgumentError, "generator name must be snake_case path" unless location && location.match?(NAME)
        if %w[endpoint action route].include?(kind) && !location.include?("/")
          raise ArgumentError, "action location must be resource/action"
        end
        options = {method: "GET", path: "/#{location}", name: location.tr("/", "_"), view: false, before: [], concerns: []}
        parser = OptionParser.new do |o|
          o.on("--method METHOD") { |v| options[:method] = v }
          o.on("--path PATH") { |v| options[:path] = v }
          o.on("--name NAME") { |v| options[:name] = v }
          o.on("--[no-]view") { |v| options[:view] = v }
          o.on("--before METHOD") { |v| options[:before] << v }
          o.on("--concern MODULE") { |v| options[:concerns] << v }
          o.on("--to CONSTANT") { |v| options[:to] = v }
          o.on("--timestamp VERSION") { |v| options[:timestamp] = v }
          o.on("--dry-run") { options[:dry_run] = true }
          o.on("--json") { options[:json] = true }
        end
        parser.parse!(args)
        raise ArgumentError, "unexpected generator arguments" unless kind == "table" || args.empty?
        raise ArgumentError, "unsupported HTTP method" unless METHODS.include?(options[:method])
        raise ArgumentError, "invalid route path" unless options[:path].match?(%r{\A/[a-zA-Z0-9_:/-]*\z})
        raise ArgumentError, "invalid route name" unless options[:name].match?(/\A[a-z][a-z0-9_]*\z/)
        raise ArgumentError, "invalid callback method" unless options[:before].all? { |v| v.match?(/\A[a-z_][a-z0-9_]*[!?]?\z/) }
        raise ArgumentError, "invalid concern constant" unless options[:concerns].all? { |v| v.match?(CONSTANT) }
        raise ArgumentError, "invalid action constant" if options[:to] && !options[:to].match?(CONSTANT)
        namespace = camel(JSON.parse(File.read(File.join(root, "config/hamster.json"))).fetch("name"))
        plan = Plan.new(root)
        action = "#{namespace}::Routes::#{camel(location)}::Action"
        case kind
        when "endpoint", "action"
          source = +"# frozen_string_literal: true\n"
          modules = [namespace, "Routes"] + location.split("/").map { |part| camel(part) }
          modules.each { |name| source << "module #{name}\n" }
          source << "class Action < Hamster::Action::Base\n"
          options[:concerns].each { |name| source << "  include #{name}\n" }
          options[:before].each { |name| source << "  before_action :#{name}\n" }
          response = options[:view] ? "view: #{location.inspect}" : "body: #{location.inspect}"
          source << "  def call\n    respond(#{response})\n  end\nend\n" << "end\n" * modules.size
          plan.add("app/routes/#{location}/action.rb", source)
          view(plan, location) if options[:view]
          if kind == "endpoint"
            route(plan, namespace, location, action, options)
            test_path = options[:path].gsub(/:[a-zA-Z0-9_]+/, "1")
            expected = options[:view] ? location.split('/').map { |part| camel(part) }.join(' ') : location
            plan.add("test/requests/#{location}_test.rb", "require_relative #{('../' * (location.count('/') + 1) + 'test_helper').inspect}\nclass #{camel(location).delete(':')}RequestTest < AppRequestTest\n  def test_generated_endpoint\n    response = client.request(#{options[:method].inspect}, #{test_path.inspect})\n    assert_status :ok, response\n#{options[:method] == "HEAD" ? '    assert_content_type "text/html", response' : "    assert_html #{expected.inspect}, response"}\n  end\nend\n")
          end
        when "stimulus"
          name = location.split('/').last
          relative = "../" * location.split('/').length + "vendor/stimulus.js"
          plan.add("app/assets/controllers/#{location}_controller.js", "import { Controller } from #{relative.inspect};\nexport default class extends Controller {\n  static targets = [\"output\"];\n  greet() { this.outputTarget.textContent = \"Hello from #{name}\"; }\n}\n")
        when "form"
          plan.add("app/views/forms/#{location}.html.erb", "<%# locals: form %>\n<%= form.start %>\n<%= form.error_summary %>\n<%= form.label(:title) %>\n<%= form.text(:title) %>\n<%= form.error(:title) %>\n<%= form.submit(\"Save\") %>\n<%= form.finish %>\n")
          plan.add("app/forms/#{location}.rb", "# frozen_string_literal: true\nmodule #{namespace}\nclass #{camel(location).delete(':')}Form < Hamster::Form\n  field :title, type: :string, required: true, max_length: 200\nend\nend\n")
        when "component"
          plan.add("app/views/components/#{location}.html.erb", "<%# locals: content %>\n<section><%= content %></section>\n")
        when "view"
          view(plan, location)
        when "route"
          action = options[:to] || action
          sources = Dir.glob(File.join(root, "app/**/*.rb")).sort.map { |p| File.read(p) }
          unless Build::Callbacks.compile(sources).include?("class #{action}\n")
            raise ArgumentError, "action not found; generate action #{location} first"
          end
          route(plan, namespace, location, action, options)
        when "table"
          raise ArgumentError, "table name must not contain /" if location.include?("/")
          columns = args.map do |field|
            name, type, extra = field.split(":", 3)
            raise ArgumentError, "use column:type with bigint, integer, text, boolean or timestamptz" unless !extra && name.match?(/\A[a-z][a-z0-9_]*\z/) && Read::TYPES.key?(type&.to_sym)
            raise ArgumentError, "id is generated automatically" if name == "id"
            "  column :#{name}, type: :#{type}, write: :both\n"
          end
          raise ArgumentError, "duplicate column" unless args.map { |v| v.split(":").first }.uniq.length == args.length
          plan.add("db/tables/#{location}.rb", "# frozen_string_literal: true\nrequire 'hamster/data'\nmodule #{namespace}\nclass #{camel(location)} < Hamster::Table\n  table :#{location}\n  column :id, type: :bigint, nullable: false\n#{columns.join}end\nend\n")
        when "migration"
          raise ArgumentError, "migration name must not contain /" if location.include?("/")
          version = options[:timestamp] || Time.now.utc.strftime("%Y%m%d%H%M%S")
          raise ArgumentError, "migration version must be 14 digits" unless version.match?(/\A[0-9]{14}\z/)
          raise ArgumentError, "migration version already exists" unless Dir.glob(File.join(root, "db/migrations/#{version}_*")).empty?
          plan.add("db/migrations/#{version}_#{location}.rb", "# frozen_string_literal: true\nrequire 'hamster/migration'\nclass #{camel(location)} < Hamster::Migration\n  def up\n    raise NotImplementedError, 'Implement migration up before running'\n  end\n\n  def down\n    raise NotImplementedError, 'Implement migration down before running'\n  end\nend\n")
        end
        plan.validate!
        plan.apply! unless options[:dry_run]
        result = {"format_version" => 1, "generator" => kind, "name" => location, "dry_run" => !!options[:dry_run], "files" => plan.files.keys.sort}
        options[:json] ? puts(JSON.generate(result)) : puts("#{options[:dry_run] ? 'Would generate' : 'Generated'} #{kind} #{location}: #{result['files'].join(', ')}")
        result
      end

      def view(plan, location)
        plan.add("app/routes/#{location}/view.html.erb", "<h1>#{location.split('/').map { |p| camel(p) }.join(' ')}</h1>\n")
      end

      def route(plan, namespace, location, action, options)
        path = "app/routes/mappings.rb"
        plan.safe!(path)
        mapping = File.read(File.join(plan.root, path))
        skeleton = /\A# frozen_string_literal: true\nmodule #{Regexp.escape(namespace)}\n  module Routes\n    class Mappings < Hamster::Routing::Base\n(.*?)    end\n  end\nend\n?\z/m
        match = mapping.match(skeleton)
        raise ArgumentError, "Customized route layout; generation requires the conventional Mappings class" unless match
        match[1].lines.each do |line|
          next if line.strip.empty? || line.strip.start_with?("#")
          parsed = line.match(/\A      (get|head|post|patch|delete) "([^"]+)", to: ([A-Z][A-Za-z0-9_:]*), as: :([a-z][a-z0-9_]*)\s*\z/)
          raise ArgumentError, "Customized route declarations; use literal routes with explicit names" unless parsed
          canonical = ->(p) { p.gsub(/:[a-zA-Z0-9_]+/, ":param") }
          if parsed[4] == options[:name] || (parsed[1].upcase == options[:method] && canonical.call(parsed[2]) == canonical.call(options[:path]))
            raise ArgumentError, "route path/method or name already exists"
          end
        end
        insertion = "      #{options[:method].downcase} #{options[:path].inspect}, to: #{action}, as: :#{options[:name]}\n"
        plan.add(path, mapping.sub(/    end\n  end\nend\n?\z/, insertion + "    end\n  end\nend\n"), replace: true)
      end
    end
  end
end
