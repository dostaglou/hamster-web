# frozen_string_literal: true
require "securerandom"
require_relative "web/json"

module Hamster
  module Jobs
    class Error < StandardError; end
    class PayloadError < Error; end
    class UnknownJob < Error; end
    class Overloaded < Error; end
    class Stopped < Error; end
    class Cancellation
      def initialize; @lock = Mutex.new; @requested = false; end
      def request!; @lock.synchronize { @requested = true }; end
      def requested?; @lock.synchronize { @requested }; end
    end
    MAX_BYTES = 65536
    @classes = {}
    class << self
      def database; @database || raise(Error, "Configure a job database pool explicitly"); end
      def database=(database); @database = database; end
      def cancelled?
        token = Thread.current[:hamster_job_cancellation]
        token ? token.requested? : false
      end
      def register(klass)
        name = klass.job_name
        previous = @classes[name]
        raise ArgumentError, "Duplicate job name #{name}" if previous && previous != klass
        @classes[name] = klass
      end
      def classes; @classes; end
      def configure(adapter:)
        raise Error, "Shut down the existing async adapter before reconfiguration" if @adapter && @adapter.respond_to?(:running?) && @adapter.running?
        @adapter = adapter
      end
      def adapter; @adapter ||= Inline.new; end
      def envelope(name, version, arguments, metadata = {})
        value = {"format_version" => 1, "id" => SecureRandom.hex(16), "job" => name, "version" => version, "arguments" => arguments, "metadata" => metadata}
        bytes = JSONValue.generate(value)
        validate(bytes)
        bytes
      end
      def validate(bytes)
        raise PayloadError, "Job payload exceeds 64 KiB" unless bytes.is_a?(String) && bytes.bytesize <= MAX_BYTES
        begin
          value = JSON.parse(bytes)
        rescue StandardError
          raise PayloadError, "Malformed job JSON"
        end
        unless value.is_a?(Hash) && value["format_version"] == 1 && value["id"].is_a?(String) && value["id"].match?(/\A[0-9a-f]{32}\z/) && value["job"].is_a?(String) && value["version"].is_a?(Integer) && value["arguments"].is_a?(Hash) && value["metadata"].is_a?(Hash)
          raise PayloadError, "Invalid job envelope"
        end
        JSONValue.normalize(value)
        raise UnknownJob, "Unknown job or payload version" unless CompiledJobs.accepts?(value["job"], value["version"])
        value
      end
      def execute(bytes)
        value = validate(bytes)
        previous = Thread.current[:hamster_job_context]
        Thread.current[:hamster_job_context] = value["metadata"]
        begin
          CompiledJobs.execute_registered_job(value["job"], value["version"], value["arguments"])
        ensure
          Thread.current[:hamster_job_context] = previous
        end
      end
      def shutdown(timeout: 10.0)
        @adapter ? @adapter.shutdown(timeout: timeout) : true
      end
    end
  end

  module CompiledJobs
    def self.accepts?(name, version)
      if RUBY_ENGINE == "ruby"
        klass = Jobs.classes[name]
        !!(klass && klass.accepted_versions.include?(version))
      else
        false
      end
    end
    def self.execute_registered_job(name, version, arguments)
      if RUBY_ENGINE == "ruby"
        klass = Jobs.classes[name]
        raise Jobs::UnknownJob, "Unknown job #{name}" unless klass && klass.accepted_versions.include?(version)
        klass.new.perform(arguments, version: version)
      else
        raise Jobs::UnknownJob, "Run hamster manifest to generate the job registry"
      end
    end
  end

  class Job
    def self.job(name, version: 1, accepts: [])
      raise ArgumentError, "invalid job name" unless name.is_a?(String) && name.match?(/\A[a-z][a-z0-9_.-]*\z/)
      versions = (accepts + [version]).uniq
      raise ArgumentError, "job versions must be positive integers" unless versions.all? { |v| v.is_a?(Integer) && v > 0 }
      @job_name, @job_version, @accepted_versions = name.dup.freeze, version, versions.freeze
      Jobs.register(self) if RUBY_ENGINE == "ruby"
    end
    def self.job_name; @job_name || raise(ArgumentError, "Declare a literal job name"); end
    def self.job_version; @job_version || 1; end
    def self.accepted_versions; @accepted_versions || [job_version]; end
    def self.perform_now(arguments = {})
      Jobs.execute(Jobs.envelope(job_name, job_version, arguments))
    end
    def self.perform_later(arguments = {}, metadata: {}, at: nil, queue: nil, priority: nil, connection: nil)
      Jobs.adapter.enqueue(Jobs.envelope(job_name, job_version, arguments, metadata), at: at, queue: queue, priority: priority, connection: connection)
    end
    def perform(arguments, version:)
      raise NotImplementedError, "Implement perform(arguments, version:)"
    end
  end
end
require_relative "jobs/adapters"
