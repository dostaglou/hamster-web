# frozen_string_literal: true
module __APP_MODULE__
  class Application < Hamster::Application
    def initialize(routes:, database:)
      super(routes: routes, database: database)
      @liveness_router = Hamster::Router.new(routes)
    end

    def call(env)
      # Liveness checks process/HTTP dispatch only, even during a DB outage.
      return @liveness_router.call(env) if env.fetch("PATH_INFO", "/") == "/up"
      super
    end
  end
end
