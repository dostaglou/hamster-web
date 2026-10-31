# frozen_string_literal: true
require "optparse"
require "tmpdir"
require "fileutils"
require_relative "build/manifest"

module Hamster
  module EndpointGenerator
    module_function
    def schema
      {"format_version" => 1, "generators" => {"endpoint" => {"arguments" => ["resource/action"], "options" => {"--method" => %w[GET HEAD POST PATCH DELETE], "--path" => "absolute route path", "--name" => "route name", "--view" => "boolean", "--before" => "existing callback method; repeatable", "--concern" => "existing module constant; repeatable"}}}}
    end
    def run(root, arguments)
      if arguments == ["--schema"]
        puts JSON.generate(schema)
        return
      end
      if arguments.empty? || arguments == ["--help"] || arguments == ["endpoint", "--help"]
        puts "Usage: bin/hamster generate endpoint resource/action [--method GET] [--path /resource/action] [--name route_name] [--view] [--before method] [--concern Module]"
        return
      end
      args = arguments.dup
      raise ArgumentError, "Unknown generator; run bin/hamster generate --help" unless args.shift == "endpoint"
      location = args.shift
      raise ArgumentError, "endpoint location must be resource/action (snake_case)" unless location && location.match?(%r{\A[a-z][a-z0-9_]*(?:/[a-z][a-z0-9_]*)+\z})
      options = {method: "GET", path: "/#{location}", name: location.tr("/", "_"), view: false, before: [], concerns: []}
      parser = OptionParser.new do |o|
        o.on("--method METHOD") { |v| options[:method] = v }
        o.on("--path PATH") { |v| options[:path] = v }
        o.on("--name NAME") { |v| options[:name] = v }
        o.on("--view") { options[:view] = true }
        o.on("--before METHOD") { |v| options[:before] << v }
        o.on("--concern MODULE") { |v| options[:concerns] << v }
      end
      parser.parse!(args)
      raise ArgumentError, "unexpected generator arguments" unless args.empty?
      raise ArgumentError, "unsupported HTTP method" unless %w[GET HEAD POST PATCH DELETE].include?(options[:method])
      raise ArgumentError, "invalid route path" unless options[:path].match?(%r{\A/(?:[a-zA-Z0-9_:/-]*)\z})
      raise ArgumentError, "invalid route name" unless options[:name].match?(/\A[a-z][a-z0-9_]*\z/)
      raise ArgumentError, "invalid callback method" unless options[:before].all? { |v| v.match?(/\A[a-z_][a-z0-9_]*[!?]?\z/) }
      raise ArgumentError, "invalid concern constant" unless options[:concerns].all? { |v| v.match?(/\A[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*\z/) }
      metadata = JSON.parse(File.read(File.join(root, "config/hamster.json")))
      namespace = metadata.fetch("name").split("_").map(&:capitalize).join
      %w[app db config].each do |folder|
        raise ArgumentError, "symlink application directory: #{folder}" if File.symlink?(File.join(root, folder))
      end
      route_file = "app/routes/mappings.rb"
      mapping = File.read(File.join(root, route_file))
      skeleton = /\A# frozen_string_literal: true\nmodule #{Regexp.escape(namespace)}\n  module Routes\n    class Mappings < Hamster::Routing::Base\n(.*?)    end\n  end\nend\n?\z/m
      match = mapping.match(skeleton)
      raise ArgumentError, "Customized route layout; use the conventional Mappings class before generation" unless match
      routes = []
      match[1].lines.each do |line|
        next if line.strip.empty? || line.strip.start_with?("#")
        parsed = line.match(/\A      (get|head|post|patch|delete) "([^"]+)", to: ([A-Z][A-Za-z0-9_:]*), as: :([a-z][a-z0-9_]*)\s*\z/)
        raise ArgumentError, "Customized route declarations; generation requires literal routes with explicit names" unless parsed
        routes << parsed
      end
      raise ArgumentError, "route path/method or name already exists" if routes.any? { |r| r[4] == options[:name] || (r[1].upcase == options[:method] && r[2] == options[:path]) }
      modules = location.split("/").map { |part| part.split("_").map(&:capitalize).join }
      action = ([namespace, "Routes"] + modules + ["Action"]).join("::")
      source = "# frozen_string_literal: true\n"
      ([namespace, "Routes"] + modules).each { |name| source += "module #{name}\n" }
      source += "class Action < Hamster::Action::Base\n"
      options[:concerns].each { |name| source += "  include #{name}\n" }
      options[:before].each { |name| source += "  before_action :#{name}\n" }
      source += "  def call\n"
      source += options[:view] ? "    respond(view: #{location.inspect})\n" : "    respond(body: #{location.inspect})\n"
      source += "  end\nend\n" + "end\n" * (modules.size + 2)
      outputs = {"app/routes/#{location}/action.rb" => source}
      outputs["app/routes/#{location}/view.html.erb"] = "<h1>#{modules.join(' ')}</h1>\n" if options[:view]
      outputs.each_key do |path|
        raise ArgumentError, "endpoint file exists: #{path}" if File.exist?(File.join(root, path))
        cursor = root
        path.split("/").each do |part|
          cursor = File.join(cursor, part)
          raise ArgumentError, "symlink generator path: #{path}" if File.symlink?(cursor)
        end
      end
      raise ArgumentError, "symlink route file" if File.symlink?(File.join(root, route_file))
      insertion = "      #{options[:method].downcase} #{options[:path].inspect}, to: #{action}, as: :#{options[:name]}\n"
      outputs[route_file] = mapping.sub(/    end\n  end\nend\n?\z/, insertion + "    end\n  end\nend\n")
      Dir.mktmpdir("hamster-endpoint") do |staging|
        %w[app db config].each do |folder|
          origin = File.join(root, folder)
          FileUtils.cp_r(origin, staging) if File.directory?(origin)
        end
        outputs.each do |path, content|
          FileUtils.mkdir_p(File.dirname(File.join(staging, path)))
          File.write(File.join(staging, path), content)
        end
        outputs.merge!(Build::Manifest.outputs(staging))
        outputs.each_key do |path|
          cursor = root
          path.split("/").each do |part|
            cursor = File.join(cursor, part)
            raise ArgumentError, "symlink generated output: #{path}" if File.symlink?(cursor)
          end
        end
        outputs.each do |path, content|
          target = File.join(root, path)
          FileUtils.mkdir_p(File.dirname(target))
          File.write(target, content)
        end
      end
      puts "Generated endpoint #{location}; run bin/hamster manifest:check and bin/hamster build"
    end
  end
end
