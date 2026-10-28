# frozen_string_literal: true

module Hamster
  module Routing
    class Route
      attr_reader :name, :method, :pattern, :action

      def initialize(name, method, pattern, action)
        @name, @method, @pattern, @action = name, method, pattern, action
        @segments = pattern.split("/").reject(&:empty?)
      end

      def match(request_method, path, method_only: false)
        return nil unless method_only || method == request_method

        path_segments = path.split("/").reject(&:empty?)
        return nil unless path_segments.length == @segments.length

        params = {}
        @segments.zip(path_segments).each do |route_segment, path_segment|
          if route_segment.start_with?(":")
            return nil if route_segment == ":id" && !path_segment.match?(/\A[0-9]+\z/)
            params[route_segment.delete_prefix(":")] = path_segment
          elsif route_segment != path_segment
            return nil
          end
        end
        params
      end

      def path(params = {}, query: {}, **keywords)
        params = params.merge(keywords)
        required = @segments.select { |segment| segment.start_with?(":") }.map { |segment| segment.delete_prefix(":") }
        supplied = params.keys.map(&:to_s)
        missing, extra = required - supplied, supplied - required
        raise ArgumentError, "#{name}: missing path parameter #{missing.join(', ')}" unless missing.empty?
        raise ArgumentError, "#{name}: unknown path parameter #{extra.join(', ')}" unless extra.empty?

        segments = @segments.map do |segment|
          next segment unless segment.start_with?(":")
          key = segment.delete_prefix(":")
          value = params.key?(key.to_sym) ? params[key.to_sym] : params[key]
          raise ArgumentError, "#{name}: empty path parameter #{key}" if value.nil? || value.to_s.empty?
          raise ArgumentError, "#{name}: #{key} must be numeric" if key == "id" && !value.to_s.match?(/\A[0-9]+\z/)
          self.class.encode(value)
        end
        result = "/#{segments.join('/')}"
        query.empty? ? result : "#{result}?#{query.map { |key, value| "#{self.class.encode(key)}=#{self.class.encode(value)}" }.join('&')}"
      end

      def self.encode(value)
        value.to_s.bytes.map do |byte|
          if (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || [45, 46, 95, 126].include?(byte)
            byte.chr
          else
            "%#{byte.to_s(16).upcase.rjust(2, '0')}"
          end
        end.join
      end
    end

    class Base
      SUPPORTED_METHODS = %w[GET POST PATCH DELETE].freeze
      CONVENTIONAL_ACTIONS = {"New" => "new", "Edit" => "edit", "Create" => "create", "Update" => "update", "Destroy" => "destroy"}.freeze

      def self.routes
        (@routes ||= []).dup.freeze
      end

      def self.get(path, to:, as: nil); add_route("GET", path, to, as); end
      def self.post(path, to:, as: nil); add_route("POST", path, to, as); end
      def self.patch(path, to:, as: nil); add_route("PATCH", path, to, as); end
      def self.delete(path, to:, as: nil); add_route("DELETE", path, to, as); end

      def self.namespace(name, &block)
        raise ArgumentError, "namespace requires a block" unless block
        segment = name.to_s
        raise ArgumentError, "invalid namespace #{name.inspect}" unless segment.match?(/\A[a-z][a-z0-9_]*\z/)
        scopes = @route_scopes ||= []
        scopes << segment
        block.call
      ensure
        scopes.pop if scopes && !scopes.empty?
      end

      def self.add_route(method, path, action, name)
        raise ArgumentError, "unsupported HTTP method #{method}" unless SUPPORTED_METHODS.include?(method)
        raise ArgumentError, "route path must be a literal absolute path" unless path.is_a?(String) && path.start_with?("/") && !path.include?("?")
        raise ArgumentError, "route action must be a class" unless action.is_a?(Class)
        route_table = @routes ||= []
        prefix = (@route_scopes || []).join("_")
        path_prefix = (@route_scopes || []).join("/")
        path = "/#{path_prefix}#{path == "/" ? "" : path}" unless path_prefix.empty?
        name = name || infer_name(method, path, action)
        name = "#{prefix}_#{name}".to_sym unless prefix.empty?
        raise ArgumentError, "route name must be a Symbol" unless name.is_a?(Symbol)
        raise ArgumentError, "duplicate route name #{name}" if route_table.any? { |route| route.name == name }

        route_table << Route.new(name, method, path, action)
        route_table.last
      end

      def self.infer_name(method, path, action)
        parts = path.split("/").reject(&:empty?)
        return :root if parts.empty?
        action_parts = action.name.to_s.split("::")
        action_name = action_parts[-1] == "Action" ? action_parts[-2] : action_parts.last
        resource = parts.find { |part| !part.start_with?(":") }
        resource = resource.sub(/s\z/, "") if parts.any? { |part| part.start_with?(":") } || CONVENTIONAL_ACTIONS.key?(action_name)
        conventional = CONVENTIONAL_ACTIONS[action_name]
        return "#{conventional}_#{resource}".to_sym if conventional && resource
        return resource.to_sym if method == "GET" && parts.length == 1 && !parts.first.start_with?(":")
        return resource.to_sym if method == "GET" && parts.length == 2 && parts.last.start_with?(":")
        container = action_name || "route"
        container.gsub(/([a-z0-9])([A-Z])/, '\\1_\\2').downcase.to_sym
      end

      def self.path(name, params = {}, query: {}, **keywords)
        route = routes.find { |candidate| candidate.name == name.to_sym }
        raise ArgumentError, "unknown route #{name}" unless route
        route.path(params, query: query, **keywords)
      end

      def self.url(name, params = {}, query: {}, base_url:, **keywords)
        base = base_url.to_s.sub(%r{/+\z}, "")
        raise ArgumentError, "base_url must be an absolute URL" unless base.match?(%r{\Ahttps?://[^/]+})
        "#{base}#{path(name, params, query: query, **keywords)}"
      end
    end
  end
end
