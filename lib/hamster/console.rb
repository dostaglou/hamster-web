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
            start(workspace)
          end
        end
      elsif block_given?
        yield binding
      else
        start(binding)
      end
    ensure
      application.shutdown
    end

    def self.start(workspace)
      require "irb"
      IRB.setup(__FILE__, argv: [])
      IRB::Irb.new(IRB::WorkSpace.new(workspace)).run(IRB.conf)
    end
    private_class_method :start
  end
end
