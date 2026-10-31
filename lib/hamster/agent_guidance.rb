# frozen_string_literal: true
require "json"
require "digest"
require "fileutils"
require_relative "web/version"

module Hamster
  module AgentGuidance
    module_function
    def contents
      template = File.expand_path("../../templates/app", __dir__)
      paths = ["AGENTS.md"] + Dir.glob(".agents/skills/**/SKILL.md", base: template).sort
      paths.to_h { |path| [path, File.read(File.join(template, path)).gsub("__HAMSTER_VERSION__", Web::VERSION)] }
    end
    def install(root, dry_run: false)
      marker = File.join(root, ".agents/hamster-guidance.json")
      raise ArgumentError, "guidance marker cannot be a symlink" if File.symlink?(marker)
      previous = File.file?(marker) ? JSON.parse(File.read(marker)).fetch("files") : {}
      desired = contents
      conflicts = []
      changes = []
      desired.each do |path, content|
        target = File.join(root, path)
        cursor = root
        path.split("/").each do |part|
          cursor = File.join(cursor, part)
          raise ArgumentError, "guidance path cannot be a symlink: #{path}" if File.symlink?(cursor)
        end
        if File.exist?(target) && !File.file?(target)
          conflicts << path
          next
        end
        actual = File.file?(target) ? File.read(target) : nil
        next if actual == content
        if actual.nil? || previous[path] == Digest::SHA256.hexdigest(actual)
          changes << path
        else
          conflicts << path
        end
      end
      changes.each { |path| puts "#{dry_run ? 'Would write' : 'Write'} #{path}" }
      conflicts.each { |path| warn "Preserved customized #{path}; compare with the current Hamster template and merge guidance manually" }
      unless dry_run
        changes.each do |path|
          target = File.join(root, path)
          FileUtils.mkdir_p(File.dirname(target))
          File.write(target, desired.fetch(path))
        end
        managed = desired.reject { |path, _| conflicts.include?(path) }.transform_values { |content| Digest::SHA256.hexdigest(content) }
        FileUtils.mkdir_p(File.dirname(marker))
        File.write(marker, JSON.pretty_generate({"format_version" => 1, "framework_version" => Web::VERSION, "files" => previous.merge(managed)}) + "\n")
      end
      conflicts.empty?
    end
  end
end
