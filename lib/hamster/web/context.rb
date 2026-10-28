# frozen_string_literal: true

module Hamster
  class Context
    attr_reader :env, :connection

    def initialize(env, connection = nil)
      @env = env
      @connection = connection
    end

    def params
      env.fetch("route_params", {})
    end

    def form
      @form ||= Http.parse_parameters(env.fetch("rack.input").read.to_s)
    end

    def same_origin?
      expected = "#{env.fetch('rack.url_scheme', 'http')}://#{env.fetch('HTTP_HOST', '')}"
      env["HTTP_ORIGIN"] == expected
    end
  end
end
