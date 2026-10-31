# frozen_string_literal: true
module Hamster
  module Turbo
    ACTIONS = %w[replace append prepend remove update].freeze
    module_function
    def identifier(value)
      id = value.to_s
      raise ArgumentError, "invalid Turbo DOM id" unless id.match?(/\A[a-zA-Z][a-zA-Z0-9_:.-]*\z/)
      id
    end
    def frame(id, content, attributes = {})
      raise ArgumentError, "frame attributes cannot override id" if attributes.keys.any? { |key| key.to_s == "id" }
      HTML.tag("turbo-frame", content, attributes.merge(id: identifier(id)))
    end
    def stream(action, target, content = nil)
      raise ArgumentError, "unsupported Turbo stream action" unless ACTIONS.include?(action.to_s)
      raise ArgumentError, "remove does not accept content" if action.to_s == "remove" && !content.nil?
      template = action.to_s == "remove" ? nil : HTML.tag("template", content)
      HTML.tag("turbo-stream", template, action: action, target: identifier(target))
    end
  end
end
