# frozen_string_literal: true

require "time"

module Hamster
  class KeyedRow
    def initialize(attributes)
      @attributes = Read.snapshot(attributes)
      freeze
    end

    def [](name)
      fetch(name)
    end

    def fetch(name)
      key = name.to_sym
      raise MissingAttributeError, "Unloaded attribute #{key}" unless @attributes.key?(key)
      @attributes[key]
    end

    def to_h
      @attributes.dup
    end
  end

  module Read
    class Decoder
      def initialize(compiled)
        @compiled = compiled
      end

      def decode(result)
        expected = @compiled.outputs.map { |out| out[:name] }
        unless result.columns == expected && result.columns.uniq.length == result.columns.length
          raise DecodeError, "Result columns do not match the projection"
        end
        types = @compiled.outputs.map { |out| TYPES[out[:type]] }
        raise DecodeError, "Result PostgreSQL type IDs do not match the projection" unless result.types == types
        row_class = @compiled.row_class
        result.rows.map do |cells|
          raise DecodeError, "Result row width does not match the projection" unless cells.length == expected.length
          attributes = {}
          @compiled.outputs.each_with_index do |out, index|
            attributes[out[:name].to_sym] = cell(cells[index], out)
          end
          if @compiled.result_class
            @compiled.result_class.new(attributes)
          elsif @compiled.table_rows
            row_class.new(attributes)
          else
            KeyedRow.new(attributes)
          end
        end
      end

      def cell(value, output)
        if value.nil?
          raise DecodeError, "Unexpected NULL for #{output[:name]}" unless output[:nullable]
          return nil
        end
        raise DecodeError, "Expected raw text cell for #{output[:name]}" unless value.is_a?(String)
        case output[:type]
        when :text then value.dup
        when :integer, :bigint
          raise DecodeError, "Malformed integer for #{output[:name]}" unless value.match?(/\A-?[0-9]+\z/)
          begin
            number = value.to_i
          rescue RangeError
            raise DecodeError, "Integer out of range for #{output[:name]}"
          end
          low, high = output[:type] == :integer ? [-2147483648, 2147483647] : [-9223372036854775808, 9223372036854775807]
          raise DecodeError, "Integer out of range for #{output[:name]}" unless number >= low && number <= high
          number
        when :boolean
          return true if value == "t"
          return false if value == "f"
          raise DecodeError, "Malformed boolean for #{output[:name]}"
        when :timestamptz
          # PostgreSQL ISO DateStyle uses a space and may emit an hour-only offset.
          unless value.match?(/\A[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?[+-][0-9]{2}(:[0-9]{2})?\z/)
            raise DecodeError, "Malformed timestamp for #{output[:name]}"
          end
          normalized = value.sub(" ", "T")
          normalized += ":00" if normalized.match?(/[+-][0-9]{2}\z/)
          begin
            timestamp = Time.iso8601(normalized)
            unless timestamp.strftime("%Y-%m-%dT%H:%M:%S") == normalized[0, 19]
              raise DecodeError, "Malformed timestamp for #{output[:name]}"
            end
            timestamp
          rescue ArgumentError
            raise DecodeError, "Malformed timestamp for #{output[:name]}"
          end
        else
          raise DecodeError, "Unsupported output type"
        end
      end
    end
  end
end
