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
      claim_body!(:form)
      if multipart?
        parse_multipart.fields
      else
        @form ||= Http.parse_parameters(env.fetch("rack.input").read.to_s)
      end
    end

    def claim_body!(kind)
      if @body_kind && @body_kind != kind
        raise RequestBodyError.new(400, "Request body was already parsed in another format")
      end
      @body_kind = kind
    end

    def json
      claim_body!(:json)
      return @json if @json_parsed
      media = env.fetch("CONTENT_TYPE", "").split(";", 2).first.to_s.strip.downcase
      unless media == "application/json" || media.match?(%r{\Aapplication/[a-z0-9!#$&^_.+-]+\+json\z})
        raise RequestBodyError.new(415, "Expected an application/json request body")
      end
      maximum = env.fetch("hamster.json_max_bytes", 1048576)
      raise ArgumentError, "JSON body limit must be a positive integer" unless maximum.is_a?(Integer) && maximum > 0
      bytes = +""
      input = env.fetch("rack.input")
      while (chunk = input.read([65536, maximum + 1 - bytes.bytesize].min))
        break if chunk.empty?
        bytes << chunk
        raise RequestBodyError.new(413, "JSON request body is too large") if bytes.bytesize > maximum
      end
      bytes.force_encoding("UTF-8")
      raise RequestBodyError.new(400, "JSON request body must be UTF-8") unless bytes.valid_encoding?
      begin
        @json = JSON.parse(bytes)
        JSONValue.normalize(@json)
      rescue StandardError
        raise RequestBodyError.new(400, "Malformed or unsupported JSON request body")
      end
      @json_parsed = true
      @json
    end

    # Explicit negotiation: callers choose their JSON/HTML/Turbo response branch.
    # Most-specific media ranges override wildcards, including q=0 exclusions.
    def format
      @negotiated = true
      accept = env.fetch("HTTP_ACCEPT", "").to_s
      return :html if accept.strip.empty?
      candidates = [[:html, "text/html"], [:json, "application/json"], [:turbo_stream, "text/vnd.turbo-stream.html"]]
      winner, best = :none, 0.0
      candidates.each do |kind, mime|
        specificity, quality = -1, 0.0
        accept.split(",").each do |range|
          parts = range.strip.downcase.split(";").map(&:strip)
          media = parts.shift
          score = media == mime ? 2 : (media == mime.split("/").first + "/*" ? 1 : (media == "*/*" ? 0 : -1))
          next if score < 0
          q = 1.0
          parts.each do |part|
            if part.start_with?("q=")
              value = part.delete_prefix("q=")
              q = value.match?(/\A(?:0(?:\.[0-9]{0,3})?|1(?:\.0{0,3})?)\z/) ? value.to_f : 0.0
            end
          end
          if score > specificity || (score == specificity && q > quality)
            specificity, quality = score, q
          end
        end
        if quality > best
          winner, best = kind, quality
        end
      end
      winner
    end

    def wants_json?
      format == :json
    end

    def response_headers(headers)
      return headers unless @negotiated
      result = headers.dup
      vary = result.fetch("vary", "").split(",").map(&:strip).reject(&:empty?)
      result["vary"] = (vary + ["Accept", "Turbo-Frame"]).uniq.join(", ")
      result
    end

    def multipart?
      env.fetch("CONTENT_TYPE", "").downcase.start_with?("multipart/")
    end

    def parse_multipart
      claim_body!(:form)
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
