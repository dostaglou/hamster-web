# frozen_string_literal: true

module Hamster
  module Console
    def self.run(application)
      app = application
      database = application.database
      puts "Hamster console (app, application, database)"
      if database
        database.with_connection do |connection|
          workspace = binding
          if block_given?
            yield workspace
          else
            require "irb"
            workspace.irb
          end
        end
      elsif block_given?
        yield binding
      else
        require "irb"
        binding.irb
      end
    ensure
      application.shutdown
    end
  end
end
