# frozen_string_literal: true
module Hamster
  class Form
    CONTROL_FIELDS = %w[csrf_token _method].freeze
    TYPES = [:string, :integer, :boolean].freeze
    MESSAGES = {"missing" => "is required", "blank" => "must not be blank", "malformed" => "has an invalid format",
                "too_short" => "is too short", "too_long" => "is too long", "unauthorized" => "is not permitted",
                "unknown_fields" => "contains undeclared fields"}.freeze
    attr_reader :errors, :error_codes
    def self.inherited(child)
      child.set_definition(fields, @model, @operation)
    end
    def self.set_definition(fields, model, operation)
      @fields, @model, @operation = fields.dup, model, operation
    end
    def self.fields; (@fields || {}).dup; end
    def self.model(table, operation: :create)
      raise ArgumentError, "form operation must be create or update" unless [:create, :update].include?(operation)
      @model, @operation = table, operation
    end
    def self.model_class; @model; end
    def self.operation; @operation || :create; end
    def self.field(name, type: :string, required: false, min_length: nil, max_length: nil, sensitive: false)
      key = name.to_s
      raise ArgumentError, "reserved form control field" if CONTROL_FIELDS.include?(key)
      raise ArgumentError, "invalid form field" unless key.match?(/\A[a-z][a-z0-9_]*\z/)
      raise ArgumentError, "field shadows form method" if Form.method_defined?(key) || Form.private_method_defined?(key)
      raise ArgumentError, "unsupported input type" unless TYPES.include?(type)
      raise ArgumentError, "form flags must be boolean" unless [true, false].include?(required) && [true, false].include?(sensitive)
      [min_length, max_length].compact.each { |v| raise ArgumentError, "length must be nonnegative" unless v.is_a?(Integer) && v >= 0 }
      raise ArgumentError, "inverted length bounds" if min_length && max_length && min_length > max_length
      @fields = fields.merge(key => {type: type, required: required, min_length: min_length, max_length: max_length, sensitive: sensitive}.freeze)
      define_method(key) { self[key] } if RUBY_ENGINE == "ruby"
    end
    def initialize(input = {})
      raise ArgumentError, "form input must be a Hash" unless input.is_a?(Hash)
      @errors, @error_codes, @values, @attributes = {}, {}, {}, {}
      supplied = {}
      input.each { |key, value| supplied[key.to_s] = value unless CONTROL_FIELDS.include?(key.to_s) }
      definitions = self.class.fields
      reject("_base", "unknown_fields") unless (supplied.keys - definitions.keys).empty?
      model = self.class.model_class
      model.assert_enabled! if model
      definitions.each do |name, spec|
        if model
          model.assert_column_enabled!(name)
          allowed = self.class.operation == :create ? model.create_fields : model.update_fields
          unless allowed.include?(name)
            reject(name, "unauthorized") if supplied.key?(name)
            next
          end
        end
        unless supplied.key?(name)
          reject(name, "missing") if spec[:required]
          next
        end
        raw = supplied[name]
        @values[name] = raw if !spec[:sensitive] && (raw.nil? || raw.is_a?(String) || raw.is_a?(Integer) || raw == true || raw == false)
        if raw.nil? || (raw.is_a?(String) && raw.strip.empty?)
          reject(name, "blank") if spec[:required]
          @attributes[name] = spec[:type] == :string ? raw : nil
          next
        end
        value = coerce(raw, spec[:type])
        if value == :__hamster_invalid_input__
          reject(name, "malformed")
          next
        end
        if value.is_a?(String)
          reject(name, "too_short") if spec[:min_length] && value.length < spec[:min_length]
          reject(name, "too_long") if spec[:max_length] && value.length > spec[:max_length]
        end
        @attributes[name] = value
      end
    end
    def coerce(value, type)
      case type
      when :string
        return value if value.is_a?(String) && value.valid_encoding?
      when :integer
        return value if value.is_a?(Integer)
        if value.is_a?(String) && value.match?(/\A-?[0-9]+\z/)
          number = value.to_i
          return number if number >= -9223372036854775808 && number <= 9223372036854775807
        end
      when :boolean
        return true if value == true || value == "1" || value == "true"
        return false if value == false || value == "0" || value == "false"
      end
      :__hamster_invalid_input__
    end
    def reject(name, code = "unauthorized")
      raise ArgumentError, "unknown form error code" unless MESSAGES.key?(code)
      key = name.to_s
      @errors[key] ||= []
      @error_codes[key] ||= []
      @errors[key] << MESSAGES[code] unless @errors[key].include?(MESSAGES[code])
      @error_codes[key] << code unless @error_codes[key].include?(code)
      @attributes.delete(key)
      self
    end
    def valid?; errors.empty?; end
    def [](name); @attributes[name.to_s]; end
    def attributes
      raise ArgumentError, "cannot persist invalid form" unless valid?
      @attributes.to_h { |name, value| [name.to_sym, value] }
    end
    def values; @values.dup; end
  end
end
