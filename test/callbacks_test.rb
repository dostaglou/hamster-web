require "minitest/autorun"
require "tmpdir"
require_relative "../lib/hamster/web"
require_relative "../lib/hamster/build/callbacks"

class CallbacksTest < Minitest::Test
  SOURCE = <<~'SOURCE'
    module CallbackFixture
      module Auth
        extend Hamster::Action::Callbacks
        before_action :authenticate
        def authenticate
          return respond(body: "unauthorized", status: :unauthorized) if context.env["deny"]
          @events = "auth"
          nil
        end
      end
      class Parent < Hamster::Action::Base
        before_action :first
        def first
          @events = "first"
          nil
        end
      end
      class Endpoint < Parent
        include Auth
        include Auth
        after_action :audit
        def call
          raise "failure" if context.env["fail"]
          respond(body: @events)
        end
        def audit(response)
          response[1]["audit"] = "yes"
          nil
        end
      end
      class Resource < Hamster::Action::Base
        after_action :replace_body
        after_action :fail_after
        def call
          [200, {}, context.env["original"]]
        end
        def replace_body(response)
          [200, {}, context.env["replacement"]]
        end
        def fail_after(response)
          raise "after hook failed"
        end
      end
    end
  SOURCE

  def setup
    return if Object.const_defined?(:CallbackFixture)
    Dir.mktmpdir do |root|
      File.write("#{root}/actions.rb", SOURCE)
      File.write("#{root}/callbacks.rb", Hamster::Build::Callbacks.compile([SOURCE]))
      load "#{root}/actions.rb"
      load "#{root}/callbacks.rb"
    end
  end

  def test_success_halt_exception_and_isolation
    2.times do
      response = CallbackFixture::Endpoint.new(Hamster::Context.new({})).dispatch
      assert_equal "auth", response[2].join
      assert_equal "yes", response[1]["audit"]
    end
    halted = CallbackFixture::Endpoint.new(Hamster::Context.new({"deny" => true})).dispatch
    assert_equal 401, halted[0]
    refute halted[1].key?("audit")
    assert_raises(RuntimeError) { CallbackFixture::Endpoint.new(Hamster::Context.new({"fail" => true})).dispatch }
    output = Hamster::Build::Callbacks.compile([SOURCE])
    assert_equal 1, output.scan("result = authenticate").size
    assert_operator output.index("result = first"), :<, output.index("result = authenticate")
  end

  def test_replacement_stream_cleanup_after_callback_failure
    body_type = Class.new do
      attr_reader :closed
      def each; yield "chunk"; end
      def close; @closed = true; end
    end
    original, replacement = body_type.new, body_type.new
    context = Hamster::Context.new({"original" => original, "replacement" => replacement})
    assert_raises(RuntimeError) { CallbackFixture::Resource.new(context).dispatch }
    assert original.closed
    assert replacement.closed
  end

  def test_dependency_order_for_concerns_and_parent_actions
    sources = {
      "a.rb" => "module App; module A; include B; end; class Child < Parent; end; end",
      "z.rb" => "module App; module B; end; class Parent < Hamster::Action::Base; end; end"
    }
    assert_equal %w[z.rb a.rb], Hamster::Build::Callbacks.order(sources)
    assert_raises(ArgumentError) do
      Hamster::Build::Callbacks.order({"a.rb" => "module A; include B; end", "b.rb" => "module B; include A; end"})
    end
  end

  def test_static_callback_validation
    assert_raises(ArgumentError) { Hamster::Build::Callbacks.compile(["class Broken < Hamster::Action::Base; before_action :missing; end"]) }
    assert_raises(ArgumentError) { Hamster::Build::Callbacks.compile(["class Broken < Hamster::Action::Base; before_action callback_name; end"]) }
    assert_raises(ArgumentError) { Hamster::Action::Base.new(Hamster::Context.new({})).send(:callback_response, false) }
  end
end
