# frozen_string_literal: true

module Hamster
  class Database
    class Result
      attr_reader :columns, :rows, :types, :command_tag

      def initialize(columns:, rows:, types:, command_tag:)
        @columns = columns
        @rows = rows
        @types = types
        @command_tag = command_tag
      end

      def each_row
        return enum_for(:each_row) unless block_given?

        rows.each { |row| yield row }
      end

      def hashes
        rows.map do |row|
          columns.each_with_index.each_with_object({}) do |(column, index), result|
            result[column] = row[index]
          end
        end
      end
    end
  end
end
