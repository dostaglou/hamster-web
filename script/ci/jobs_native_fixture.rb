require "hamster/jobs"
module NativeJobState
  def self.setup; @count = 0; @lock = Mutex.new; end
  def self.add; @lock.synchronize { @count += 1 }; end
  def self.count; @lock.synchronize { @count }; end
end
class NativeCPUJob < Hamster::Job
  job "native.cpu", version: 1
  def perform(arguments, version:)
    raise "connection leaked" if Thread.current[:hamster_record_connection]
    total = 0
    100000.times { |n| total += n }
    raise "cpu result" unless total == 4999950000
    NativeJobState.add
    total
  end
end
class NativeFailJob < Hamster::Job
  job "native.failure"
  def perform(arguments, version:); raise "job failure"; end
end
NativeJobState.setup
raise "inline" unless NativeCPUJob.perform_now({}) == 4999950000
adapter = Hamster::Jobs::Async.new(threads: 2, capacity: 8)
Hamster::Jobs.configure(adapter: adapter)
Thread.current[:hamster_record_connection] = "request sentinel"
4.times { NativeCPUJob.perform_later({}) }
NativeFailJob.perform_later({})
raise "drain" unless adapter.shutdown(timeout: 10)
raise "jobs lost" unless NativeJobState.count == 5
raise "failure isolation" unless adapter.failures.length == 1
puts "JOBS_NATIVE_OK"
