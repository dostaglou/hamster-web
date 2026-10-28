# frozen_string_literal: true
require_relative "data"

module Hamster
  module SchemaValidation
    def self.run(database, tables = Table.registry)
      database.with_connection { |connection| Read::Schema.validate(connection, tables) }
    ensure
      database.shutdown
    end
  end
end
