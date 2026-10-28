# frozen_string_literal: true
# CRuby command adapter; keep it out of the compiled server require chain.
require_relative "application"

module Hamster
  module ApplicationCommands
    def self.build
      __APP_MODULE__.build
    end

    def self.database
      Hamster::Database.new(__APP_MODULE__.database_configuration,
                           migrations_path: File.join(__APP_MODULE__.root, "db/migrations"))
    end
  end
end
