# frozen_string_literal: true

module Hamster
  class Application
    attr_reader :database
    attr_writer :upload_options

    def initialize(routes:, database: nil)
      @router = Router.new(routes)
      @database = database
      @upload_options = {}
    end

    def call(env)
      asset = Assets.response(env)
      return asset if asset
      env["hamster.upload_options"] = @upload_options
      return @router.call(env) unless database
      database.with_connection { |connection| @router.call(env, connection) }
    rescue RequestBodyError => error
      Http.response(error.status, error.message)
    rescue StandardError
      Http.response(500, "<!doctype html><title>Server error</title><h1>Server error</h1>")
    end

    def shutdown
      database.shutdown if database
    end
  end
end
