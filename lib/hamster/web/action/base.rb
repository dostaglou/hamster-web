# frozen_string_literal: true

module Hamster
  module Action
    module Callbacks
      def before_action(name); end
      def after_action(name); end
    end

    class Base
      extend Callbacks
      UNSET = :__hamster_unset_response__
      STATUSES = {ok: 200, created: 201, no_content: 204, bad_request: 400, not_acceptable: 406, unsupported_media_type: 415, payload_too_large: 413, see_other: 303, unauthorized: 401, forbidden: 403,
                  not_found: 404, method_not_allowed: 405, unprocessable_entity: 422,
                  upgrade_required: 426, service_unavailable: 503}.freeze
      attr_reader :context

      def self.status_code(status)
        return status unless status.is_a?(Symbol)
        STATUSES.fetch(status) { raise ArgumentError, "unknown HTTP status #{status.inspect}" }
      end

      def initialize(context)
        @context = context
      end

      def self.before_action(name); end
      def self.after_action(name); end

      def dispatch
        halted = run_before_actions
        return halted unless halted.nil?
        response = callback_response(call)
        run_after_actions(response)
      rescue StandardError
        response[2].close if response && response[2].respond_to?(:close)
        raise
      end

      private

      def run_before_actions; nil; end
      def run_after_actions(response); response; end

      def callback_response(response)
        unless response.is_a?(Array) && response.length == 3 && response[0].is_a?(Integer) && response[0] >= 100 && response[0] <= 599 && response[1].is_a?(Hash) && (response[2].respond_to?(:each) || response[0] == 101)
          raise ArgumentError, "callback/action must return an HTTP response or nil (callbacks only)"
        end
        response
      end

      def respond(view: nil, body: nil, json: UNSET, locals: {}, layout: "layouts/application",
                  status: :ok, type: :html, headers: {})
        count = (view.nil? ? 0 : 1) + (body.nil? ? 0 : 1) + (json == UNSET ? 0 : 1)
        raise ArgumentError, "respond requires exactly one of view:, body:, or json:" unless count == 1
        unless json == UNSET
          body = JSONValue.generate(json)
          type = :json
        end
        raise ArgumentError, "respond locals: must be a Hash" unless locals.is_a?(Hash)
        body = Hamster::View.render(view, locals, layout: layout) if view
        Http.response(status, body, context.response_headers(headers), type: type)
      end

      def send_file(path, root:, filename: nil, content_type: "application/octet-stream", disposition: "attachment")
        Downloads.file(path, root: root, filename: filename, content_type: content_type, disposition: disposition)
      end

      def send_data(data, filename:, content_type: "application/octet-stream", disposition: "attachment")
        headers = Downloads.headers(filename, content_type, disposition)
        body = data.is_a?(String) ? [data.b] : FileBody.new(data)
        [200, headers, body]
      end

      def redirect_to(path, cookie: nil)
        Http.redirect(path, cookie: cookie)
      end

      def upgrade(handler)
        [101, {"cache-control" => "no-store"}, handler]
      end
    end
  end
end
