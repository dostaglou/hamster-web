# frozen_string_literal: true

module Hamster
  module View
    class Form
      METHODS = %w[GET POST PATCH DELETE].freeze
      FIELD = /\A[a-z][a-z0-9_]*\z/

      def initialize(action:, method: "POST", csrf_token: nil, values: {}, errors: {}, namespace: nil)
        @action = action.to_s
        View.validate_url!(@action, "form", 1)
        @method = method.to_s.upcase
        raise ArgumentError, "unsupported form method #{@method}" unless METHODS.include?(@method)
        if @method != "GET" && csrf_token.to_s.empty?
          raise ArgumentError, "CSRF token is required for #{@method} forms"
        end
        @csrf_token = csrf_token
        @values = values
        @errors = errors
        raise ArgumentError, "invalid form namespace" if namespace && !namespace.to_s.match?(FIELD)
        @namespace = namespace
      end

      def start(attributes = {})
        raise ArgumentError, "form attributes cannot override action or method" if attributes.keys.any? { |key| %w[action method].include?(key.to_s) }

        form_attributes = {method: @method == "GET" ? "get" : "post", action: @action}.merge(attributes)
        # The fixed form tag and validated attributes are safe to mark as HTML.
        opening = HTML.raw_reviewed("<form#{HTML.attribute_text(form_attributes)}>")
        return opening if @method == "GET"

        fields = [opening, HTML.tag(:input, nil, type: "hidden", name: "csrf_token", value: @csrf_token)]
        fields << HTML.tag(:input, nil, type: "hidden", name: "_method", value: @method) unless @method == "POST"
        HTML.join(fields)
      end

      def text(name, attributes = {})
        reject_value_attribute!(attributes)
        type = attributes.fetch(:type, "text").to_s
        field = field_attributes(name, attributes.merge(type: type))
        field[:value] = value_for(name) unless type == "password"
        HTML.tag(:input, nil, field)
      end

      def textarea(name, attributes = {})
        reject_value_attribute!(attributes)
        HTML.tag(:textarea, value_for(name), field_attributes(name, attributes))
      end

      def hidden(name, value: nil)
        actual = value.nil? ? value_for(name) : value
        HTML.tag(:input, nil, name: field_name(name), id: field_id(name), type: "hidden", value: actual)
      end

      def checkbox(name, value: "1", attributes: {})
        reject_value_attribute!(attributes)
        checked = value_for(name) == true || value_for(name).to_s == value.to_s
        HTML.tag(:input, nil, field_attributes(name, attributes.merge(type: "checkbox", value: value, checked: checked)))
      end

      def select(name, options, attributes = {})
        selected = value_for(name).to_s
        choices = options.map do |label, value|
          HTML.tag(:option, label, value: value, selected: value.to_s == selected)
        end
        HTML.tag(:select, HTML.join(choices), field_attributes(name, attributes))
      end

      def submit(label, attributes = {})
        HTML.tag(:button, label, attributes.merge(type: "submit"))
      end

      def error(name)
        message = error_for(name)
        return HTML.join([]) if message.nil? || message.to_s.empty?

        HTML.tag(:p, message, id: "#{field_id(name)}-error", class: "error", role: "alert")
      end

      def field_id(name)
        base = field_name(name).tr("_", "-")
        @namespace ? "#{@namespace}-#{base}" : base
      end

      private

      def field_name(name)
        text = name.to_s
        raise ArgumentError, "invalid form field #{text}" unless text.match?(FIELD)

        text
      end

      def field_attributes(name, attributes)
        raise ArgumentError, "field attributes cannot override name or id" if attributes.keys.any? { |key| %w[name id].include?(key.to_s) }

        field = {name: field_name(name), id: field_id(name)}.merge(attributes)
        message = error_for(name)
        unless message.nil? || message.to_s.empty?
          aria = attributes.fetch(:aria, {}).merge(invalid: "true", describedby: "#{field_id(name)}-error")
          field[:aria] = aria
        end
        field
      end

      def value_for(name)
        @values.key?(name.to_sym) ? @values[name.to_sym] : @values[name.to_s]
      end

      def error_for(name)
        @errors.key?(name.to_sym) ? @errors[name.to_sym] : @errors[name.to_s]
      end

      def reject_value_attribute!(attributes)
        raise ArgumentError, "pass form values to Form.new" if attributes.keys.any? { |key| key.to_s == "value" }
      end
    end
  end
end
