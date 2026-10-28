# frozen_string_literal: true

module Hamster
  class Database
    class Error < StandardError
      attr_reader :original, :sqlstate

      def initialize(message, original: nil, sqlstate: nil)
        super(message)
        @original = original
        @sqlstate = sqlstate
      end
    end

    class ConfigurationError < Error; end
    class CheckoutTimeout < Error; end
    class ConnectionError < Error; end
    class QueryError < Error; end
    class TransactionError < Error; end
  end
end
