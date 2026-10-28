# frozen_string_literal: true

module Hamster
  module Record
    class Error < StandardError
      attr_reader :result

      def initialize(result)
        @result = result
        super(result.errors.join(", "))
      end
    end

    class ValidationError < Error; end
    class ConflictError < Error; end
    class NotFoundError < Error; end
    class PersistenceError < Error; end
    class MissingConnection < StandardError; end

    class Result
      attr_reader :record, :code, :errors, :cause

      def initialize(record:, code: nil, errors: [], cause: nil)
        @record = record
        @code = code
        @errors = errors
        @cause = cause
      end

      def success?
        code.nil?
      end

      def value!
        return record if success?

        error_class = case code
                      when :invalid then ValidationError
                      when :conflict then ConflictError
                      when :not_found then NotFoundError
                      else PersistenceError
                      end
        raise error_class.new(self)
      end
    end

    def self.with_connection(connection)
      previous = Thread.current[:hamster_record_connection]
      Thread.current[:hamster_record_connection] = connection
      yield
    ensure
      Thread.current[:hamster_record_connection] = previous
    end

    def self.connection
      Thread.current[:hamster_record_connection] ||
        raise(MissingConnection, "Bind a database connection with Hamster::Record.with_connection")
    end


    def initialize(attributes = nil, **keywords)
      source = attributes || keywords
      @attributes = {}
      source.each { |key, value| @attributes[key.to_sym] = value }
      @partial = !attributes.nil?
    end

    def [](name)
      key = name.to_sym
      raise MissingAttributeError, "Unloaded attribute #{key}" if @partial && !@attributes.key?(key)
      raise MissingAttributeError, "Undeclared attribute #{key}" unless self.class.columns.key?(key)
      @attributes[key]
    end

    def write_attribute(name, value)
      @attributes[name.to_sym] = value
    end
  end

  class MissingAttributeError < StandardError; end
end
