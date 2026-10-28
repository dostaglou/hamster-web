# frozen_string_literal: true

module Hamster
  class Application
    attr_reader :database

    def initialize(routes:, database: nil)
      @router = Router.new(routes)
      @database = database
    end

    def call(env)
      return @router.call(env) unless database
      database.with_connection { |connection| @router.call(env, connection) }
    rescue StandardError
      Http.response(500, "<!doctype html><title>Server error</title><h1>Server error</h1>")
    end

    def shutdown
      database.shutdown if database
    end
  end
end
