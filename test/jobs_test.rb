require "minitest/autorun"
require "timeout"
require_relative "../lib/hamster/jobs"
require_relative "../lib/hamster/build/jobs"
class JobsTest < Minitest::Test
  class Echo < Hamster::Job
    job "test.echo", version: 2, accepts: [1]
    def perform(arguments, version:)
      [arguments, version]
    end
  end
  class Failure < Hamster::Job
    job "test.failure"
    def perform(arguments, version:); raise "private payload details"; end
  end
  class Gate < Hamster::Job
    job "test.gate"
    STARTED = Queue.new
    RELEASE = Queue.new
    def perform(arguments, version:)
      raise "request connection leaked" if Thread.current[:hamster_record_connection]
      STARTED << true
      RELEASE.pop
    end
  end
  def teardown
    Hamster::Jobs.shutdown(timeout: 1)
    Hamster::Jobs.configure(adapter: Hamster::Jobs::Inline.new)
  end
  def test_versioned_json_contract_and_test_adapter_are_deterministic
    assert_equal [{"message" => "Hello"}, 2], Echo.perform_now(message: "Hello")
    adapter = Hamster::Jobs::TestAdapter.new
    Hamster::Jobs.configure(adapter: adapter)
    id = Echo.perform_later({message: "日本語"}, metadata: {trace_id: "explicit"})
    assert_match(/\A[0-9a-f]{32}\z/, id)
    value = JSON.parse(adapter.enqueued.first)
    assert_equal({"message" => "日本語"}, value["arguments"])
    assert_equal 2, value["version"]
    adapter.perform_enqueued
    assert_empty adapter.enqueued
    assert_raises(Hamster::Jobs::PayloadError) { Echo.perform_now("not a hash") }
    assert_raises(ArgumentError) { Echo.perform_later({connection: Object.new}) }
    assert_raises(Hamster::Jobs::PayloadError) { Echo.perform_later({large: "x" * 65536}) }
    assert_raises(Hamster::Jobs::UnknownJob) { Hamster::Jobs.envelope("test.echo", 3, {}) }
    assert Hamster::Jobs.validate(Hamster::Jobs.envelope("test.echo", 1, {}))
  end
  def test_async_backpressure_connection_isolation_and_bounded_shutdown
    adapter = Hamster::Jobs::Async.new(threads: 1, capacity: 1)
    Hamster::Jobs.configure(adapter: adapter)
    Thread.current[:hamster_record_connection] = Object.new
    Gate.perform_later
    Timeout.timeout(2) { Gate::STARTED.pop }
    Gate.perform_later
    assert_raises(Hamster::Jobs::Overloaded) { Gate.perform_later }
    refute adapter.shutdown(timeout: 0.01)
    assert_equal 1, adapter.dropped
    assert_raises(Hamster::Jobs::Stopped) { Gate.perform_later }
    Gate::RELEASE << true
    assert adapter.shutdown(timeout: 1)
    refute adapter.running?
  ensure
    Thread.current[:hamster_record_connection] = nil
    Gate::RELEASE << true
    adapter&.shutdown(timeout: 1)
  end
  def test_async_failure_does_not_kill_worker_or_leak_payloads
    adapter = Hamster::Jobs::Async.new(threads: 2)
    Hamster::Jobs.configure(adapter: adapter)
    Failure.perform_later
    Echo.perform_later({message: "still running"})
    assert adapter.shutdown(timeout: 1)
    assert_equal 1, adapter.failures.length
    refute_includes JSON.generate(adapter.failures), "private payload"
    assert_equal "RuntimeError", adapter.failures.first["error_class"]
  end
  def test_static_registry_refuses_duplicates_and_dynamic_declarations
    one = 'class A < Hamster::Job; job "a", version: 1; def perform(arguments, version:); 1; end; end'
    assert_includes Hamster::Build::Jobs.compile([one]), 'A.new.perform(arguments, version: version)'
    assert_raises(ArgumentError) { Hamster::Build::Jobs.compile([one, one.sub('class A', 'class B')]) }
    assert_raises(ArgumentError) { Hamster::Build::Jobs.compile([one.sub('"a"', 'name')]) }
  end
end
