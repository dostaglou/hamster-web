# frozen_string_literal: true
require "json"
require "open3"
require "rbconfig"
module Hamster
  module TestRunner
    module_function
    def run(root, arguments)
      args = arguments.dup
      json = !!args.delete("--json")
      raise ArgumentError, "Usage: test [test/path] [--json]" unless args.length <= 1 && args.none? { |arg| arg.start_with?("-") }
      base = File.realpath(File.join(root, "test"))
      target = args.empty? ? base : File.expand_path(args.first, root)
      raise ArgumentError, "test path must be inside test/" unless File.realpath(target).start_with?(base + "/") || File.realpath(target) == base
      files = File.directory?(target) ? Dir.glob(File.join(target, "**/*_test.rb")).sort : [target]
      files.each do |path|
        raise ArgumentError, "invalid test file" unless path.end_with?(".rb") && File.realpath(path).start_with?(base + "/")
      end
      raise ArgumentError, "No tests found" if files.empty?
      output, status = Open3.capture2e({"HAMSTER_ENV" => "test"}, RbConfig.ruby, "-I", File.expand_path("..", __dir__), "-Itest", "-e", 'ARGV.each { |path| require File.expand_path(path) }', *files, chdir: root)
      if json
        puts JSON.generate({"format_version" => 1, "valid" => status.success?, "files" => files.map { |path| path.delete_prefix(root + "/") }, "exit_status" => status.exitstatus, "output" => output})
      else
        puts output
      end
      status.success? ? 0 : 1
    end
  end
end
