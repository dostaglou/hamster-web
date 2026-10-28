# frozen_string_literal: true

module Hamster
  class Database
    class Pool
      def initialize(configuration)
        @configuration = configuration
        @lock = Mutex.new
        @ready = ConditionVariable.new
        @available = []
        @total = 0
        @borrowed = 0
        @closed = false
      end

      def checkout
        connection = reserve
        begin
          connection ||= Connection.new(Postgres.connect(@configuration))
        rescue StandardError
          release_failed_reservation
          raise
        end
        connection
      end

      def checkin(connection)
        reusable = connection.usable?
        if reusable && !connection.idle?
          begin
            connection.execute("ROLLBACK")
            reusable = connection.idle?
          rescue StandardError
            reusable = false
          end
        end

        connection.close unless reusable
        @lock.synchronize do
          @borrowed -= 1
          if reusable && !@closed
            @available << connection
          else
            @total -= 1
          end
          @ready.broadcast
        end
      end

      def shutdown
        available = @lock.synchronize do
          @closed = true
          connections = @available
          @available = []
          @ready.broadcast
          connections
        end
        available.each(&:close)
      end

      private

      def reserve
        deadline = Time.now + @configuration.checkout_timeout
        @lock.synchronize do
          loop do
            raise ConnectionError, "database pool is shut down" if @closed

            connection = @available.pop
            if connection
              @borrowed += 1
              return connection
            end

            if @total < @configuration.pool_size
              @total += 1
              @borrowed += 1
              return nil
            end

            remaining = deadline - Time.now
            raise CheckoutTimeout, "database pool checkout timed out" unless remaining.positive?

            @ready.wait(@lock, remaining)
          end
        end
      end

      def release_failed_reservation
        @lock.synchronize do
          @total -= 1
          @borrowed -= 1
          @ready.broadcast
        end
      end
    end
  end
end
