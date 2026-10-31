require "hamster/web"
require "stringio"
module Hamster
  module CompiledViews
    def self.render(name, context, locals)
      Hamster::HTML::Fragment.new("")
    end
  end
end
class JsonNative < Hamster::Action::Base
  def call
    context.wants_json? ? respond(json: context.json, status: :created) : respond(body: "HTML")
  end
end
class JsonRoutes < Hamster::Routing::Base
  post "/json", to: JsonNative
end
app = Hamster::Application.new(routes: JsonRoutes)
input = JSON.generate({"text" => "日本語\n\"\\", "nested" => [nil, true, false, 12, 1.5]})
response = app.call({"REQUEST_METHOD" => "POST", "PATH_INFO" => "/json", "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json", "rack.input" => StringIO.new(input)})
raise "status" unless response[0] == 201
raise "type" unless response[1]["content-type"] == "application/json; charset=utf-8"
raise "vary" unless response[1]["vary"].include?("Accept")
raise "roundtrip" unless JSON.parse(response[2].join) == JSON.parse(input)
puts "JSON_NATIVE_OK"
