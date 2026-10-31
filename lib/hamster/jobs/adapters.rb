# frozen_string_literal: true
module Hamster
  module Jobs
    class Inline
      def enqueue(bytes, at: nil, queue: nil, priority: nil, connection: nil)
        raise ArgumentError, "Scheduling and queue options require a durable adapter" if at || queue || priority || connection
        value = Jobs.validate(bytes)
        Jobs.execute(bytes)
        value["id"]
      end
      def shutdown(timeout: 10.0); true; end
    end
    class TestAdapter
      attr_reader :enqueued
      def initialize(capacity: 1000)
        @enqueued, @capacity = [], capacity
      end
      def enqueue(bytes, at: nil, queue: nil, priority: nil, connection: nil)
        raise ArgumentError, "Scheduling and queue options require a durable adapter" if at || queue || priority || connection
        value = Jobs.validate(bytes)
        raise Overloaded, "Test job queue is full" if enqueued.length >= @capacity
        enqueued << bytes.dup.freeze
        value["id"]
      end
      def perform_enqueued
        Jobs.execute(enqueued.shift) until enqueued.empty?
      end
      def clear; enqueued.clear; end
      def shutdown(timeout: 10.0); true; end
    end
    class Async
      attr_reader :dropped
      def initialize(threads: 2, capacity: 64)
        raise ArgumentError, "threads/capacity must be positive integers" unless [threads, capacity].all? { |n| n.is_a?(Integer) && n > 0 }
        @queue, @failures, @workers = [], [], []
        @lock, @ready = Mutex.new, ConditionVariable.new
        @capacity, @stopping, @active, @dropped = capacity, false, 0, 0
        begin
          threads.times { @workers << Thread.new { work } }
        rescue Exception
          shutdown(timeout: 1)
          raise
        end
      end
      def now; Process.clock_gettime(Process::CLOCK_MONOTONIC); end
      def enqueue(bytes, at: nil, queue: nil, priority: nil, connection: nil)
        raise ArgumentError, "Scheduling and queue options require a durable adapter" if at || queue || priority || connection
        value = Jobs.validate(bytes)
        @lock.synchronize do
          raise Stopped, "Async jobs are stopping" if @stopping
          raise Overloaded, "Async job queue is full" if @queue.length >= @capacity
          @queue << bytes.dup.freeze
          @ready.signal
        end
        value["id"]
      end
      def take
        @lock.synchronize do
          @ready.wait(@lock) while @queue.empty? && !@stopping
          return nil if @queue.empty?
          @active += 1
          @queue.shift
        end
      end
      def work
        loop do
          bytes = take
          break unless bytes
          previous = Thread.current[:hamster_record_connection]
          Thread.current[:hamster_record_connection] = nil
          begin
            Jobs.execute(bytes)
          rescue StandardError, NotImplementedError => error
            value = Jobs.validate(bytes)
            @lock.synchronize do
              @failures << {"id" => value["id"], "job" => value["job"], "error_class" => error.class.to_s}
              @failures.shift if @failures.length > 100
            end
          ensure
            Thread.current[:hamster_record_connection] = previous
            @lock.synchronize { @active -= 1 }
          end
        end
      end
      def failures; @lock.synchronize { @failures.map(&:dup) }; end
      def pending; @lock.synchronize { @queue.length }; end
      def active; @lock.synchronize { @active }; end
      def running?; @workers.any?(&:alive?); end
      def shutdown(timeout: 10.0)
        raise ArgumentError, "shutdown timeout must be finite and nonnegative" unless timeout.is_a?(Numeric) && timeout.finite? && timeout >= 0
        @lock.synchronize { @stopping = true; @ready.broadcast }
        deadline = now + timeout
        sleep 0.01 while running? && now < deadline
        return true unless running?
        @lock.synchronize do
          @dropped += @queue.length
          @queue.clear
          @ready.broadcast
        end
        # Arbitrary user code is not safely interruptible. Remaining threads
        # retain their bounded slots until return; process replacement recovers.
        false
      end
    end
  end
end
