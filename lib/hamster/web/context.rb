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
      if multipart?
        parse_multipart.fields
      else
        @form ||= Http.parse_parameters(env.fetch("rack.input").read.to_s)
      end
    end

    def multipart?
      env.fetch("CONTENT_TYPE", "").downcase.start_with?("multipart/")
    end

    def parse_multipart
      @multipart ||= Multipart.new(env.fetch("rack.input"), env.fetch("CONTENT_TYPE"), env.fetch("hamster.upload_options", {})).parse
    end

    def uploads
      multipart? ? parse_multipart.uploads : {}
    end

    def finish_response(response)
      response[2] = RequestBody.new(response[2], self) if @multipart && !@multipart.uploads.empty?
      response
    end

    def close_uploads
      @multipart.close if @multipart
    end

    def same_origin?
      expected = "#{env.fetch('rack.url_scheme', 'http')}://#{env.fetch('HTTP_HOST', '')}"
      env["HTTP_ORIGIN"] == expected
    end
  end
end
