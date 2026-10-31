require "minitest/autorun"
require "stringio"
require_relative "../lib/hamster/web"
class JSONTest < Minitest::Test
  class Echo < Hamster::Action::Base
    def call
      respond(json: context.json, status: :created)
    end
  end
  class Negotiated < Hamster::Action::Base
    def call
      context.wants_json? ? respond(json: {message: "日本語\n\"\\", nested: [nil, true, false, 1, 1.5]}) : respond(body: "HTML")
    end
  end
  class Routes < Hamster::Routing::Base
    post "/echo", to: Echo
    get "/negotiated", to: Negotiated
  end
  def request(body, type = "application/json")
    Hamster::Application.new(routes: Routes).call("REQUEST_METHOD" => "POST", "PATH_INFO" => "/echo", "CONTENT_TYPE" => type, "rack.input" => StringIO.new(body))
  end
  def test_parsing_errors_unicode_null_and_repeated_access
    [nil, [true, false, 1, {"a" => "日本語\n\"\\"}]].each do |value|
      response = request(JSON.generate(value))
      assert_equal 201, response[0]
      value.nil? ? assert_nil(JSON.parse(response[2].join)) : assert_equal(value, JSON.parse(response[2].join))
      assert_equal "application/json; charset=utf-8", response[1]["content-type"]
    end
    assert_equal 400, request('{"private"')[0]
    assert_equal 415, request("{}", "text/plain")[0]
    assert_equal 200 + 1, request("{}", "application/problem+json")[0]
    context = Hamster::Context.new("CONTENT_TYPE" => "application/json", "rack.input" => StringIO.new("null"))
    assert_nil context.json
    assert_nil context.json
    assert_raises(Hamster::RequestBodyError) { context.form }
    context = Hamster::Context.new("CONTENT_TYPE" => "application/json", "rack.input" => StringIO.new("12345"), "hamster.json_max_bytes" => 4)
    assert_equal 413, assert_raises(Hamster::RequestBodyError) { context.json }.status
  end
  def test_explicit_serialization_rejects_objects_cycles_and_invalid_values
    action = Negotiated.new(Hamster::Context.new({}))
    assert_equal "null", action.send(:respond, json: nil)[2].join
    assert_raises(ArgumentError) { action.send(:respond, json: {}, body: "x") }
    assert_raises(ArgumentError) { action.send(:respond, json: Object.new) }
    assert_raises(ArgumentError) { action.send(:respond, json: Float::NAN) }
    cycle = []; cycle << cycle
    assert_raises(ArgumentError) { action.send(:respond, json: cycle) }
    assert_raises(ArgumentError) { action.send(:respond, json: {a: 1, "a" => 2}) }
  end
  def test_negotiation_honors_quality_exclusions_and_varies_html
    {"application/json" => :json, "text/html;q=0.5, application/json;q=0.9" => :json,
     "application/json;q=0, */*" => :html, "text/vnd.turbo-stream.html" => :turbo_stream,
     "image/png" => :none, "*/*" => :html, "text/vnd.turbo-stream.html, text/html" => :turbo_stream}.each do |accept, expected|
      assert_equal expected, Hamster::Context.new("HTTP_ACCEPT" => accept).format
    end
    app = Hamster::Application.new(routes: Routes)
    ["application/json", "text/html"].each do |accept|
      response = app.call("PATH_INFO" => "/negotiated", "HTTP_ACCEPT" => accept)
      assert_equal 200, response[0]
      assert_includes response[1]["vary"], "Accept"
      assert_equal "日本語\n\"\\", JSON.parse(response[2].join)["message"] if accept == "application/json"
    end
  end
end
