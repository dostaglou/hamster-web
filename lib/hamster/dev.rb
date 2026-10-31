# frozen_string_literal: true
require "digest"
require "json"
require "timeout"
require_relative "check"

module Hamster
  module Dev
    class Runner
      attr_reader :root, :state, :pid
      def initialize(root, build: nil, output: $stdout, debounce: 0.2, interval: 0.1, drain_timeout: 12)
        @root, @output = File.realpath(root), output
        @build = build || -> { CLI.dispatch("build") }
        @debounce, @interval, @drain_timeout = debounce, interval, drain_timeout
        raise ArgumentError, "watch intervals must be positive" unless [debounce, interval, drain_timeout].all? { |v| v.is_a?(Numeric) && v.finite? && v > 0 }
        name = JSON.parse(File.read(File.join(root, "config/hamster.json"))).fetch("name")
        @binary = ENV.fetch("HAMSTER_SERVER_BINARY", File.join(root, "bin/#{name}-server"))
        @state = :stopped
      end
      def now; Process.clock_gettime(Process::CLOCK_MONOTONIC); end
      def say(message)
        @output.puts("hamster dev: #{message}")
        @output.flush
      end
      def snapshot
        paths = Dir.glob("{app,db,config,lib,public,assets,test}/**/*", base: root).select { |p| File.file?(File.join(root, p)) }
        paths += %w[Gemfile Gemfile.lock spin.toml spin.lock].select { |p| File.file?(File.join(root, p)) }
        paths -= %w[config/manifest.rb config/view_registry.rb config/callback_registry.rb config/asset_registry.rb]
        paths.sort.to_h { |path| [path, Digest::SHA256.file(File.join(root, path)).hexdigest] }
      rescue Errno::ENOENT
        retry
      end
      def stop!
        @stopping = true
      end
      def stop_server
        return unless @pid
        begin
          Process.kill("TERM", -@pid)
          Timeout.timeout(@drain_timeout) { Process.waitpid(@pid) }
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        rescue Timeout::Error
          Process.kill("KILL", -@pid) rescue nil
          Process.waitpid(@pid) rescue nil
        ensure
          @pid = nil
          @state = :stopped
        end
      end
      def rebuild(expected)
        @state = :building
        started = now
        say("running CRuby source checks, then native Spinel build")
        paths = Dir.glob("{app,db,config}/**/*.rb", base: root)
        invalid = paths.find { |path| !Ripper.sexp(File.read(File.join(root, path))) }
        raise "#{invalid}: invalid Ruby syntax" if invalid
        @build.call
        report = Check.run(root)
        raise report["diagnostics"].map { |d| "#{d['path']}:#{d['line']}: #{d['message']}" }.join("\n") unless report["valid"]
        return false if @stopping || snapshot != expected
        raise "Native executable missing after build: #{@binary}" unless File.executable?(@binary)
        @pid = Process.spawn(@binary, chdir: root, pgroup: true)
        @state = :running
        say("native server started pid=#{@pid}; rebuild #{format('%.3f', now - started)}s (request tests were not run)")
        true
      rescue StandardError => error
        @state = :failed
        say("build failed; server stopped\n#{error.message}")
        false
      end
      def run
        previous = {}
        %w[INT TERM].each { |signal| previous[signal] = Signal.trap(signal) { stop! } }
        observed = snapshot
        dirty_at = now - @debounce
        say("watching app/views/routes/config; Ctrl-C stops server and watcher")
        until @stopping
          current = snapshot
          if current != observed
            stop_server
            observed = current
            dirty_at = now
            say("source changed; server stopped until a successful build")
          end
          if dirty_at && now - dirty_at >= @debounce
            expected = observed
            rebuild(expected)
            after = snapshot
            if after != expected
              observed = after
              dirty_at = now
            else
              dirty_at = nil
            end
          end
          if @pid && Process.waitpid(@pid, Process::WNOHANG)
            @pid = nil
            @state = :failed
            say("native server exited; waiting for source changes")
          end
          sleep @interval
        end
      ensure
        stop_server
        previous&.each { |signal, handler| Signal.trap(signal, handler) }
      end
    end
    def self.run(root, args)
      raise ArgumentError, "Usage: dev" unless args.empty?
      Runner.new(root).run
      0
    end
  end
end
