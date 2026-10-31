# frozen_string_literal: true
require "ripper"
require "json"
require "open3"
require "rbconfig"
require "fileutils"
require_relative "build/manifest"

module Hamster
  module Check
    module_function
    class Parser < Ripper::SexpBuilderPP
      attr_reader :errors
      def initialize(source)
        super(source)
        @errors = []
      end
      def on_parse_error(message)
        @errors << [lineno, message]
      end
    end
    def diagnostic(code, message, path = nil, line = nil)
      {"code" => code, "message" => message, "path" => path, "line" => line}
    end
    def run(root, full: false)
      issues = []
      paths = Dir.glob("{app,db,config,test}/**/*.rb", base: root).sort
      paths.each do |path|
        source = File.read(File.join(root, path))
        parser = Parser.new(source)
        parser.parse
        parser.errors.each { |line, message| issues << diagnostic("ruby.syntax", message, path, line) }
      end
      if issues.empty?
        begin
          Build::Manifest.check(root).each do |message|
            path, line = location(message)
            issues << diagnostic("manifest.stale", message, path, line)
          end
        rescue StandardError => error
          path, line = location(error.message)
          issues << diagnostic("manifest.invalid", error.message, path, line)
        end
        definitions = {}
        paths.grep(%r{\A(?:app|db)/}).reject { |path| path.start_with?("db/migrations/") }.each do |path|
          Build::Callbacks.scan(Ripper.sexp(File.read(File.join(root, path))), "", definitions)
        end
        metadata = JSON.parse(File.read(File.join(root, "config/hamster.json")))
        namespace = metadata.fetch("name").split("_").map(&:capitalize).join
        route_names, route_paths = [], []
        mapping = "app/routes/mappings.rb"
        File.readlines(File.join(root, mapping)).each_with_index do |line, index|
          match = line.match(/\b(get|head|post|patch|delete) ["']([^"']+)["'], to: ([A-Z][A-Za-z0-9_:]*)(?:, as: :([a-z][a-z0-9_]*))?/)
          next unless match
          reference = match[3]
          resolved = [reference, "#{namespace}::Routes::#{reference}", "#{namespace}::#{reference}"].find { |name| definitions.key?(name) }
          issues << diagnostic("route.action_missing", "Unresolved action #{reference}", mapping, index + 1) unless resolved
          key = [match[1], match[2].gsub(/:[a-zA-Z0-9_]+/, ":param")]
          if route_paths.include?(key) || (match[4] && route_names.include?(match[4]))
            issues << diagnostic("route.duplicate", "Duplicate route method/path or name", mapping, index + 1)
          end
          route_paths << key
          route_names << match[4] if match[4]
        end
        paths.grep(%r{\Aapp/}).each do |path|
          source = File.read(File.join(root, path))
          source.lines.each_with_index do |line, index|
            line.scan(/\brespond\s*\(\s*view:\s*["']([^"']+)["']/).flatten.each do |view|
              present = ["app/routes/#{view}/view.html.erb", "app/views/#{view}.html.erb"].any? { |p| File.file?(File.join(root, p)) }
              issues << diagnostic("view.missing", "Missing view #{view}", path, index + 1) unless present
            end
          end
        end
      end
      if issues.empty?
        require_relative "application_graph"
        graph = ApplicationGraph.new(root).build.report
        graph["diagnostics"].select { |d| d["severity"] == "error" }.each do |d|
          issues << diagnostic(d["code"], d["message"], d["path"], d["line"])
        end
      end
      completed = ["syntax", "manifest", "conventions"]
      if full && issues.empty?
        test_files = Dir.glob("test/**/*_test.rb", base: root).sort
        unless test_files.empty?
          output, status = Open3.capture2e({"HAMSTER_ENV" => "test"}, RbConfig.ruby, "-I", File.expand_path("..", __dir__), "-Itest", "-e", 'ARGV.each { |path| require File.expand_path(path) }', *test_files, chdir: root)
          issues << diagnostic("test.failed", output, "test") unless status.success?
        end
        completed << "tests"
        begin
          require_relative "native_smoke"
          NativeSmoke.run(root)
        rescue StandardError => error
          issues << diagnostic("native.failed", error.message, "test/native_server.rb")
        end
        completed << "native"
      end
      {"format_version" => 1, "mode" => full ? "full" : "quick", "valid" => issues.empty?, "checks" => completed, "diagnostics" => issues}
    rescue StandardError => error
      {"format_version" => 1, "mode" => full ? "full" : "quick", "valid" => false, "checks" => [], "diagnostics" => [diagnostic("check.failed", error.message)]}
    end
    def location(message)
      match = message.match(/\A([^\s:]+)(?::(\d+))?/)
      path = match && match[1].include?("/") ? match[1] : nil
      [path, match && match[2] ? match[2].to_i : nil]
    end
    def cli(root, args)
      raise ArgumentError, "Usage: check [--quick | --full] [--json]" unless (args - %w[--quick --full --json]).empty? && !(args.include?("--quick") && args.include?("--full"))
      report = run(root, full: args.include?("--full"))
      if args.include?("--json")
        puts JSON.generate(report)
      else
        report["diagnostics"].each { |d| puts "#{d['code']} #{[d['path'], d['line']].compact.join(':')}: #{d['message']}" }
        puts "#{report['mode']} checks #{report['valid'] ? 'passed' : 'failed'}"
      end
      report["valid"] ? 0 : 1
    end

    def install_hooks(root, args)
      raise ArgumentError, "Usage: hooks:install [--pre-push]" unless (args - ["--pre-push"]).empty?
      output, status = Open3.capture2e("git", "rev-parse", "--show-toplevel", chdir: root)
      raise "Application must be a Git repository root" unless status.success? && File.realpath(output.strip) == File.realpath(root)
      files = {"pre-commit" => "--quick"}
      files["pre-push"] = "--full" if args.include?("--pre-push")
      directory = File.join(root, ".githooks")
      raise "Symlink hook directory" if File.symlink?(directory)
      files.each do |name, mode|
        path = File.join(directory, name)
        source = "#!/bin/sh\n# Managed Hamster hook\nexec bin/hamster check #{mode}\n"
        raise "Customized hook exists: #{path}" if File.exist?(path) && File.read(path) != source || File.symlink?(path)
      end
      FileUtils.mkdir_p(directory)
      files.each do |name, mode|
        path = File.join(directory, name)
        File.write(path, "#!/bin/sh\n# Managed Hamster hook\nexec bin/hamster check #{mode}\n")
        File.chmod(0755, path)
      end
      raise "Cannot configure Git hooks" unless system("git", "config", "--local", "core.hooksPath", ".githooks", chdir: root)
      puts "Installed explicit project hooks in .githooks"
      0
    end
  end
end
