# frozen_string_literal: true
require_relative "postgres_queue"
module Hamster
  module Jobs
    class Worker
      attr_reader :errors
      def initialize(queue, threads: 2, queues: ["default"], poll_interval: 0.1, drain_timeout: 10.0)
        raise ArgumentError, "worker threads must be 1..64" unless threads.is_a?(Integer) && threads >= 1 && threads <= 64
        [poll_interval, drain_timeout].each { |n| raise ArgumentError, "worker times must be positive" unless n.is_a?(Numeric) && n.finite? && n > 0 }
        @queue, @thread_count, @queues, @poll, @drain = queue, threads, queues, poll_interval, drain_timeout
        raise ArgumentError, "choose 1..32 queues" unless queues.is_a?(Array) && queues.length >= 1 && queues.length <= 32
        @queues.each { |name| queue.validate_queue(name) }
        @lock, @stopping, @errors = Mutex.new, false, []
        @identity = "#{Process.pid}-#{SecureRandom.hex(8)}"
      end
      def now; Process.clock_gettime(Process::CLOCK_MONOTONIC); end
      def stop!; @lock.synchronize { @stopping = true }; end
      def stopping?; @lock.synchronize { @stopping }; end
      def record_error(error)
        @lock.synchronize { @errors << error.class.to_s; @errors.shift if @errors.length > 100 }
      end
      def process(row)
        token = Cancellation.new
        finished, heartbeat_lock = false, Mutex.new
        previous_connection = Thread.current[:hamster_record_connection]
        previous_cancellation = Thread.current[:hamster_job_cancellation]
        Thread.current[:hamster_record_connection] = nil
        Thread.current[:hamster_job_cancellation] = token
        interval = [@queue.lease_seconds / 3.0, 1.0].min
        heartbeat = Thread.new do
          due = now + interval
          loop do
            break if heartbeat_lock.synchronize { finished }
            if now >= due
              begin
                token.request! if @queue.renew(row.fetch("id"), row.fetch("lease_token"))
              rescue StandardError => error
                token.request!
                record_error(error)
                break
              end
              due = now + interval
            end
            sleep [interval, 0.05].min
          end
        end
        begin
          Jobs.execute(row.fetch("payload"))
          @queue.complete(row.fetch("id"), row.fetch("lease_token"))
        rescue LostLease => error
          record_error(error)
        rescue StandardError, NotImplementedError => error
          begin
            @queue.fail_job(row, error.class.to_s)
          rescue StandardError => failure
            record_error(failure)
          end
        ensure
          heartbeat_lock.synchronize { finished = true }
          heartbeat.join
          Thread.current[:hamster_record_connection] = previous_connection
          Thread.current[:hamster_job_cancellation] = previous_cancellation
        end
      end
      def run_once
        @queue.recover_expired!
        row = @queue.claim(@identity, queues: @queues)
        return false unless row
        process(row)
        true
      end
      def run
        @queue.verify!
        previous = {}
        %w[TERM INT].each { |signal| previous[signal] = Signal.trap(signal) { @signal_requested = true } }
        threads = []
        @thread_count.times do
          threads << Thread.new do
            until stopping?
              begin
                worked = run_once
                sleep @poll unless worked
              rescue StandardError => error
                record_error(error)
                sleep @poll
              end
            end
          end
        end
        until stopping?
          stop! if @signal_requested
          sleep 0.05
        end
        deadline = now + @drain
        sleep 0.01 while threads.any?(&:alive?) && now < deadline
        !threads.any?(&:alive?)
      ensure
        stop!
        previous&.each { |signal, handler| Signal.trap(signal, handler) }
      end
    end
  end
end
