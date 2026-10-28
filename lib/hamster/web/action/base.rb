# frozen_string_literal: true

module Hamster
  module Action
    class Base
      STATUSES = {ok: 200, see_other: 303, unauthorized: 401, forbidden: 403,
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

      private

      def respond(view: nil, body: nil, locals: {}, layout: "layouts/application",
                  status: :ok, type: :html, headers: {})
        raise ArgumentError, "respond requires exactly one of view: or body:" if view.nil? == body.nil?
        raise ArgumentError, "respond locals: must be a Hash" unless locals.is_a?(Hash)
        body = Hamster::View.render(view, locals, layout: layout) if view
        Http.response(status, body, headers, type: type)
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
