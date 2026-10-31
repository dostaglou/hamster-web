# frozen_string_literal: true

module Hamster
  class Router
    NOT_FOUND = "<!doctype html><title>Not found</title><h1>Not found</h1>".freeze
    METHOD_NOT_ALLOWED = "<!doctype html><title>Method not allowed</title><h1>Method not allowed</h1>".freeze

    def initialize(mapping)
      @routes = mapping.routes
    end

    def call(env, connection = nil)
      method = env.fetch("REQUEST_METHOD", "GET").upcase
      path = env.fetch("PATH_INFO", "/")
      context = Context.new(env, connection)
      if method == "POST" && env.fetch("CONTENT_TYPE", "").split(";", 2).first == "application/x-www-form-urlencoded"
        override = context.form["_method"]
        method = override if ["PATCH", "DELETE"].include?(override)
      end
      route = @routes.find { |candidate| candidate.match(method, path) }
      route ||= @routes.find { |candidate| candidate.match("GET", path) } if method == "HEAD"
      unless route
        allowed = @routes.select { |candidate| candidate.match(method, path, method_only: true) }
        return Http.response(:method_not_allowed, METHOD_NOT_ALLOWED,
                             {"allow" => allowed.map(&:method).uniq.join(", ")}) unless allowed.empty?
        return Http.response(:not_found, NOT_FOUND)
      end

      env["route_params"] = route.match(method == "HEAD" && route.method == "GET" ? "GET" : method, path)
      begin
        context.finish_response(route.action.new(context).dispatch)
      rescue StandardError
        context.close_uploads
        raise
      end
    end
  end
end
