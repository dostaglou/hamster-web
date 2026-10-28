# frozen_string_literal: true

module Hamster
  module Http
    MIME = {html: "text/html; charset=utf-8", turbo: "text/html; charset=utf-8",
            turbo_stream: "text/vnd.turbo-stream.html; charset=utf-8"}.freeze
    module_function

    def parse_parameters(encoded)
      encoded.split("&").each_with_object({}) do |part, values|
        key, value = part.split("=", 2)
        values[decode(key)] = decode(value.to_s)
      end
    end

    def decode(value)
      value.to_s.gsub("+", " ").gsub(/%([0-9A-Fa-f]{2})/) { [$1.to_i(16)].pack("C") }.force_encoding("UTF-8")
    end

    def response(status, body, headers = {}, type: :html)
      content_type = MIME.fetch(type) { raise ArgumentError, "unknown response type #{type.inspect}" }
      status = Action::Base.status_code(status)
      defaults = {"content-type" => content_type, "cache-control" => "no-store"}
      defaults["vary"] = "Accept, Turbo-Frame" if type != :html
      [status, defaults.merge(headers), [body.to_s]]
    end

    def redirect(path, cookie: nil)
      headers = {"location" => path, "cache-control" => "no-store"}
      headers["set-cookie"] = cookie if cookie
      [303, headers, [""]]
    end
  end
end
