# frozen_string_literal: true
require_relative "data"

module Hamster
  module SchemaValidation
    def self.run(database, tables = Table.registry, detailed: false)
      database.with_connection do |connection|
        detailed ? Read::Schema.report(connection, tables) : Read::Schema.validate(connection, tables)
      end
    ensure
      database.shutdown
    end
  end
end
