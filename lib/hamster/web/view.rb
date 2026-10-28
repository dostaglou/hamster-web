# frozen_string_literal: true

module Hamster
  module View
    class Error < StandardError; end

    def self.configure(site_name:, routes:)
      @site_name = site_name
      @routes = routes
    end

    def self.route_mapping
      @routes
    end

    class Context
      def initialize(name = nil, locals = nil)
        @name = name
        @locals = locals
        @slots = {}
      end

      def fetch(*args)
        locals, template, name, line = if args.length == 2
                                         [@locals, @name, args[0], args[1]]
                                       else
                                         args
                                       end
        key = name.to_sym
        return locals[key] if locals.key?(key)
        return locals[name] if locals.key?(name)

        raise Error, "#{template}:#{line}: missing local #{name}"
      end

      def content_for(name, fragment)
        key = name.to_s
        @slots[key] = HTML.join([@slots[key], fragment])
        nil
      end

      def slot(name)
        @slots[name.to_s] || HTML::Fragment.new("")
      end
    end

    URL_ATTRIBUTES = %w[href src action formaction].freeze
    TOKEN = /<%=(.*?)%>/m
    NAME = /\A[a-z][a-z0-9_]*(?:\/[a-z][a-z0-9_]*)*\z/
    LOCAL = /\A[a-z][a-z0-9_]*\z/

    module_function

    def render_compiled(name, locals = {}, layout: "layouts/application")
      context = Context.new
      body = CompiledViews.render(name, context, locals)
      return body if layout.nil?

      context.content_for("body", body)
      title = context.slot("title")
      site_name = @site_name || "Hamster"
      full_title = title.to_s.empty? ? site_name : HTML.join([title, " · ", site_name])
      CompiledViews.render(layout, context, title: full_title)
    end

    def append_value(output, value, name, line, position)
      validate_url!(value, name, line) if URL_ATTRIBUTES.include?(position)
      value = HTML.escape(value.to_s) if position.is_a?(String) && value.instance_of?(HTML::Fragment)
      output << HTML.escape(value).to_s
    end

    def instrument_compiled(name)
      kind = name.start_with?("layouts/") ? "layout" : name.include?("/shared/") ? "partial" : "template"
      Hamster::Instrumentation.instrument("view.render", attributes: {"view.template" => name, "view.kind" => kind}) { yield }
    end

    def prepare!(sources)
      @templates = compile(sources)
    end

    def use_compiled!
      @templates = nil
    end

    def validate!(sources)
      compile(sources)
      true
    end

    def compile(sources)
      prepared = {}
      sources.each do |name, source|
        raise Error, "invalid template name #{name}" unless name.match?(NAME)
        instructions = []
        cursor = 0
        source.to_enum(:scan, TOKEN).each do
          match = Regexp.last_match
          prefix = source[0...match.begin(0)]
          literal = source[cursor...match.begin(0)]
          instructions << [:literal, literal.freeze] unless literal.empty?
          line = prefix.count("\n") + 1
          location = "#{name}:#{line}"
          context = position(prefix.gsub(TOKEN, ""))
          expression = match[1].strip
          unless expression.match?(LOCAL)
            raise Error, "#{location}: only <%= local %> is supported; compose partials in Ruby (got #{expression})"
          end
          raise Error, "#{location}: dynamic script or style content" if context == :script
          raise Error, "#{location}: substitution must be in text or a quoted attribute" if context == :tag
          if context.is_a?(String)
            raise Error, "#{location}: dynamic event or style attribute" if context.start_with?("on") || context == "style" || context == "srcdoc"
          end
          instructions << [:value, expression.freeze, context, line].freeze
          cursor = match.end(0)
        end
        tail = source[cursor..-1]
        instructions << [:literal, tail.freeze] unless tail.empty?
        unsupported = source.index(/<%(?!\=)/)
        if unsupported
          invalid_line = source[0...unsupported].count("\n") + 1
          raise Error, "#{name}:#{invalid_line}: unsupported ERB tag; only <%= local %> is supported"
        end
        if tail.include?("<%")
          invalid_line = source[0...cursor].count("\n") + tail[0...tail.index("<%")].count("\n") + 1
          raise Error, "#{name}:#{invalid_line}: unterminated or unsupported ERB tag"
        end
        prepared[name.freeze] = instructions.freeze
      end
      prepared.freeze
    end

    def position(prefix)
      script_tag = prefix.scan(%r{</?(?:script|style)\b[^>]*>}i).last
      return :script if script_tag && !script_tag.start_with?("</")

      open = prefix.rindex("<")
      close = prefix.rindex(">")
      if open && (!close || open > close)
        tag = prefix[open..-1]
        match = tag.match(/([a-zA-Z][a-zA-Z0-9:-]*)\s*=\s*(["'])[^"']*\z/)
        return match[1].downcase if match
        return :tag
      end
      :text
    end

    def render(name, locals = {}, kind = nil, **options)
      if RUBY_ENGINE == "ruby"
        return render_interpreted(name, locals, kind, **options) unless @templates.nil?
      end
      layout = options.delete(:layout) { "layouts/application" }
      render_compiled(name, locals.merge(options), layout: layout)
    end

    def render_interpreted(name, locals = {}, kind = nil, **options)
      if @templates.nil? && defined?(Hamster::CompiledViews)
        layout = options.delete(:layout) { "layouts/application" }
        locals = locals.merge(options)
        return render_compiled(name, locals, layout: layout)
      end
      locals = locals.merge(options) unless options.empty?
      instructions = @templates && @templates[name]
      raise Error, "missing template #{name}" unless instructions

      work = proc do
        context = Context.new(name, locals)
        output = instructions.map do |instruction|
          case instruction[0]
          when :literal then instruction[1]
          when :value
            value = context.fetch(instruction[1], instruction[3])
            validate_url!(value, name, instruction[3]) if URL_ATTRIBUTES.include?(instruction[2])
            if instruction[2].is_a?(String) && value.instance_of?(HTML::Fragment)
              HTML.escape(value.to_s).to_s
            else
              HTML.escape(value).to_s
            end
          end
        end.join
        HTML::Fragment.new(output)
      end
      kind ||= name.start_with?("layouts/") ? "layout" : "template"
      Hamster::Instrumentation.instrument("view.render", attributes: {"view.template" => name, "view.kind" => kind}) { work.call }
    end

    def validate_url!(value, name, line)
      url = value.to_s
      raise Error, "#{name}:#{line}: unsafe URL" unless url.start_with?("/") && !url.start_with?("//") && !url.match?(/[\x00-\x20\\<>"']/)
    end

    def path(name, params = {}, query: {}, **keywords)
      raise Error, "route mapping is not configured" unless @routes
      @routes.path(name, params, query: query, **keywords)
    end
  end
end
