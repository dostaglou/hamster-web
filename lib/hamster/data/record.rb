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
      assert_record_column_enabled!(key)
      raise MissingAttributeError, "Unloaded attribute #{key}" if @partial && !@attributes.key?(key)
      @attributes[key]
    end

    def assert_record_column_enabled!(name)
      if RUBY_ENGINE == "ruby"
        self.class.assert_column_enabled!(name)
        raise MissingAttributeError, "Undeclared attribute #{name}" unless self.class.columns.key?(name.to_sym)
      else
        assert_compiled_record_column_enabled!(name)
      end
    end

    def assert_compiled_record_column_enabled!(name)
      raise MissingAttributeError, "Run hamster manifest to generate record schema guards"
    end

    def write_attribute(name, value)
      assert_record_column_enabled!(name)
      @attributes[name.to_sym] = value
    end
  end

  class MissingAttributeError < StandardError; end
end
