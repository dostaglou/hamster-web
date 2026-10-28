# frozen_string_literal: true

module Hamster
  module HTML
    ATTRIBUTE_NAME = /\A[a-z][a-z0-9_:-]*\z/
    TAG_NAME = /\A[a-z][a-z0-9-]*\z/
    URL_ATTRIBUTES = %w[href src action formaction].freeze
    VOID_TAGS = %w[area base br col embed hr img input link meta param source track wbr].freeze

    class Fragment
      attr_reader :html

      def initialize(html)
        @html = html.to_s.freeze
        freeze
      end

      def to_s
        @html
      end

      def +(other)
        Fragment.new(@html + HTML.escape(other).to_s)
      end
    end

    module_function

    def escape(value)
      return value if value.instance_of?(Fragment)

      Fragment.new(value.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
        .gsub('"', "&quot;").gsub("'", "&#39;"))
    end

    # Use only where a helper has built and reviewed safe markup from escaped values.
    def raw_reviewed(html)
      Fragment.new(html)
    end

    def join(parts)
      Fragment.new(parts.map { |part| escape(part).to_s }.join)
    end

    def tag(name, content = nil, attributes = {})
      name = name.to_s
      raise ArgumentError, "invalid HTML tag" unless name.match?(TAG_NAME) && name != "script" && name != "style"

      opening = "<#{name}#{attribute_text(attributes)}>"
      return Fragment.new(opening) if VOID_TAGS.include?(name) && content.nil?
      raise ArgumentError, "#{name} cannot contain content" if VOID_TAGS.include?(name)

      Fragment.new("#{opening}#{escape(content)}</#{name}>")
    end

    def link_to(content, url, attributes = {})
      raise ArgumentError, "link attributes cannot include href" if attributes.keys.any? { |key| key.to_s == "href" }

      tag(:a, content, attributes.merge(href: url))
    end

    def attribute_text(attributes)
      attributes.map do |key, value|
        name = key.to_s.tr("_", "-")
        if name == "data" || name == "aria"
          raise ArgumentError, "#{name} must be a hash" unless value.instance_of?(Hash)
          value.map { |nested, nested_value| attribute_text("#{name}-#{nested}" => nested_value) }.join
        else
          raise ArgumentError, "invalid HTML attribute #{name}" unless name.match?(ATTRIBUTE_NAME)
          raise ArgumentError, "unsafe HTML attribute #{name}" if name.start_with?("on") || name == "style" || name == "srcdoc"
          next "" if value.nil? || value == false
          next " #{name}" if value == true

          View.validate_url!(value, "tag", 1) if URL_ATTRIBUTES.include?(name)
          " #{name}=\"#{escape(value.to_s)}\""
        end
      end.join
    end
  end
end
