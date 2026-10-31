# frozen_string_literal: true
require "tmpdir"
require "fileutils"
require_relative "../build/manifest"

module Hamster
  module Generators
    # Validate the complete proposal in isolation; never execute application code.
    class Plan
      attr_reader :root, :files
      def initialize(root)
        @root = File.realpath(root)
        @files = {}
        @expected = {}
      end

      def safe!(path)
        raise ArgumentError, "invalid generator path: #{path}" if path.start_with?("/") || path.split("/").include?("..")
        cursor = root
        path.split("/").each do |part|
          cursor = File.join(cursor, part)
          raise ArgumentError, "symlink generator path: #{path}" if File.symlink?(cursor)
        end
      end

      def add(path, content, replace: false)
        safe!(path)
        raise ArgumentError, "generator file exists: #{path}" if !replace && (files.key?(path) || File.exist?(File.join(root, path)))
        @expected[path] = File.file?(File.join(root, path)) ? File.binread(File.join(root, path)) : nil unless @expected.key?(path)
        files[path] = content.b
      end

      def validate!
        %w[app db config test public].each do |folder|
          Dir.glob("#{folder}/**/*", File::FNM_DOTMATCH, base: root).each { |path| safe!(path) }
          safe!(folder)
        end
        Dir.mktmpdir("hamster-generate") do |staging|
          %w[app db config test public].each do |folder|
            origin = File.join(root, folder)
            FileUtils.cp_r(origin, staging) if File.directory?(origin)
          end
          files.each do |path, content|
            target = File.join(staging, path)
            FileUtils.mkdir_p(File.dirname(target))
            File.write(target, content)
          end
          Dir.glob("{app,db,config}/**/*.rb", base: staging).each do |path|
            raise ArgumentError, "invalid Ruby: #{path}" unless Ripper.sexp(File.read(File.join(staging, path)))
          end
          expected = Build::Manifest.outputs(staging)
          expected.each do |path, content|
            target = File.join(staging, path)
            FileUtils.mkdir_p(File.dirname(target))
            File.binwrite(target, content)
          end
          issues = Build::Manifest.check(staging, expected: expected)
          raise ArgumentError, issues.join("\n") unless issues.empty?
          expected.each { |path, content| add(path, content, replace: true) }
        end
        files.delete_if { |path, content| File.file?(File.join(root, path)) && File.binread(File.join(root, path)) == content }
        self
      end

      def apply!
        originals, created_directories = {}, []
        files.each_key do |path|
          safe!(path)
          target = File.join(root, path)
          originals[path] = File.file?(target) ? File.binread(target) : nil
          raise ArgumentError, "File changed during generation: #{path}" unless originals[path] == @expected[path]
        end
        begin
          files.each do |path, content|
            target = File.join(root, path)
            parent = File.dirname(target)
            missing = []
            until File.directory?(parent)
              missing << parent
              parent = File.dirname(parent)
            end
            missing.reverse_each { |directory| Dir.mkdir(directory); created_directories << directory }
            File.binwrite(target, content)
          end
        rescue Exception
          originals.each do |path, content|
            target = File.join(root, path)
            content.nil? ? (File.unlink(target) if File.file?(target)) : File.binwrite(target, content)
          end
          created_directories.reverse_each { |directory| Dir.rmdir(directory) if Dir.empty?(directory) }
          raise
        end
      end
    end
  end
end
