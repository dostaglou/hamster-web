# frozen_string_literal: true
require "json"

module Hamster
  module JSONValue
    module_function
    # Normalize only explicit JSON values; never call record/object serializers.
    def normalize(value, depth = 0)
      raise ArgumentError, "JSON nesting exceeds 64 levels" if depth > 64
      case value
      when NilClass, TrueClass, FalseClass, Integer
        value
      when Float
        raise ArgumentError, "JSON numbers must be finite" unless value.finite?
        value
      when String
        raise ArgumentError, "JSON strings must be UTF-8" unless value.dup.force_encoding("UTF-8").valid_encoding?
        value
      when Array
        value.map { |item| normalize(item, depth + 1) }
      when Hash
        result = {}
        value.each do |key, item|
          raise ArgumentError, "JSON keys must be strings or symbols" unless key.is_a?(String) || key.is_a?(Symbol)
          name = key.to_s
          raise ArgumentError, "Duplicate JSON key #{name}" if result.key?(name)
          normalize(name, depth + 1)
          result[name] = normalize(item, depth + 1)
        end
        result
      else
        raise ArgumentError, "Unsupported JSON value #{value.class}; select fields explicitly"
      end
    end
    def generate(value)
      JSON.generate(normalize(value))
    end
  end
end
