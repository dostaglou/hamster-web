# frozen_string_literal: true
require "hamster/web"
require_relative "database"
require_relative "manifest"

module __APP_MODULE__
  def self.build
    Hamster::View.configure(site_name: "__APP_NAME__", routes: Routes::Mappings)
    database = Hamster::Database.new(database_configuration, migrations_path: File.join(root, "db/migrations"))
    begin
      database.verify!
      Application.new(routes: Routes::Mappings, database: database)
    rescue StandardError
      database.shutdown
      raise
    end
  end

  def self.validate_queries!
  end
end

Hamster::View.configure(site_name: "__APP_NAME__", routes: __APP_MODULE__::Routes::Mappings)
