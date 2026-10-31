# frozen_string_literal: true
# CRuby test tooling; never required by native application entrypoints.
require "minitest/autorun"
require "stringio"
require "uri"
require "json"
require "securerandom"
require_relative "web"

module Hamster
  module Testing
    class Response
      attr_reader :status, :headers, :body
      def initialize(status, headers, body)
        @status, @headers, @body = status, headers, body
      end
      def json; JSON.parse(body); end
      def content_type; headers.fetch("content-type", "").split(";", 2).first; end
    end

    class Client
      UNSET = Object.new.freeze
      def initialize(application)
        @application = application
      end
      def request(method, path, headers: {}, form: nil, json: UNSET, body: nil)
        raise ArgumentError, "choose one request body format" if [!form.nil?, json != UNSET, !body.nil?].count(true) > 1
        uri = URI.parse(path)
        raise ArgumentError, "request path must be absolute" unless uri.path.start_with?("/")
        env = {"REQUEST_METHOD" => method.upcase, "PATH_INFO" => uri.path, "QUERY_STRING" => uri.query.to_s,
               "HTTP_HOST" => uri.host || "localhost", "rack.url_scheme" => uri.scheme || "http"}
        headers.each do |name, value|
          key = name.to_s.upcase.tr("-", "_")
          env[%w[CONTENT_TYPE CONTENT_LENGTH].include?(key) ? key : "HTTP_#{key}"] = value
        end
        if form
          body = URI.encode_www_form(form)
          env["CONTENT_TYPE"] ||= "application/x-www-form-urlencoded"
        elsif json != UNSET
          body = JSONValue.generate(json)
          env["CONTENT_TYPE"] ||= "application/json"
        end
        body = body.to_s.b
        input = StringIO.new(body)
        env["CONTENT_LENGTH"] = body.bytesize.to_s
        env["rack.input"] = input
        response = nil
        begin
          response = @application.call(env)
          bytes = +"".b
          response[2].each { |chunk| bytes << chunk.b } unless method.upcase == "HEAD"
          Response.new(response[0], response[1], bytes)
        ensure
          response[2].close if response && response[2].respond_to?(:close)
          input.close
        end
      end
      def get(path, **options); request("GET", path, **options); end
      def post(path, **options); request("POST", path, **options); end
      def patch(path, **options); request("PATCH", path, **options); end
      def delete(path, **options); request("DELETE", path, **options); end
      def head(path, **options); request("HEAD", path, **options); end

      def multipart(path, fields: {}, files: {}, headers: {})
        boundary = "hamster-test-#{SecureRandom.hex(12)}"
        bytes = +"".b
        fields.each do |name, values|
          Array(values).each { |value| bytes << part(boundary, name, nil, nil, value.to_s) }
        end
        files.each do |name, values|
          (values.is_a?(Array) ? values : [values]).each do |file|
            data = file.fetch(:data)
            data = data.read if data.respond_to?(:read)
            bytes << part(boundary, name, file.fetch(:filename), file.fetch(:content_type, "application/octet-stream"), data)
          end
        end
        bytes << "--#{boundary}--\r\n"
        post(path, body: bytes, headers: headers.merge("Content-Type" => "multipart/form-data; boundary=#{boundary}"))
      end
      def part(boundary, name, filename, type, bytes)
        [name, filename, type].compact.each do |value|
          raise ArgumentError, "invalid multipart test metadata" if value.to_s.match?(/[\r\n"\\]/)
        end
        disposition = "form-data; name=\"#{name}\""
        disposition += "; filename=\"#{filename}\"" if filename
        "--#{boundary}\r\nContent-Disposition: #{disposition}\r\n#{type ? "Content-Type: #{type}\r\n" : ''}\r\n".b + bytes.b + "\r\n"
      end
    end

    module Assertions
      def assert_status(expected, response)
        assert_equal Action::Base.status_code(expected), response.status
      end
      def assert_content_type(expected, response)
        assert_equal expected, response.content_type
      end
      def assert_html(text, response)
        assert_content_type "text/html", response
        assert_includes response.body.force_encoding("UTF-8"), text
      end
      def assert_json(expected, response)
        assert_content_type "application/json", response
        assert_equal expected, response.json
      end
    end
    class Test < Minitest::Test
      include Assertions
    end
  end
end
