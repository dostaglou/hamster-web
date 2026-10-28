# frozen_string_literal: true

if RUBY_ENGINE == "ruby"
  $LOAD_PATH.unshift(File.expand_path("../vendor/packages/pg-0.2.0", __dir__))
end
require "hamster/database/postgres"

module __APP_MODULE__
  def self.root
    if RUBY_ENGINE == "ruby"
      File.expand_path("..", __dir__)
    else
      ENV.fetch("HAMSTER_APP_ROOT", Dir.pwd)
    end
  end

  def self.database_configuration
    Hamster::Database::Configuration.from_env(app_name: "__APP_NAME__")
  end
end
