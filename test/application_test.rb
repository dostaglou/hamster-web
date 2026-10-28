require "minitest/autorun"
require_relative "../lib/hamster/web"

class ApplicationTest < Minitest::Test
  class Show < Hamster::Action::Base
    def call
      respond(body: context.params.fetch("id"))
    end
  end
  class Broken < Hamster::Action::Base
    def call
      raise "private error detail"
    end
  end
  class Routes < Hamster::Routing::Base
    get "/items/:id", to: Show, as: :item
    get "/broken", to: Broken
  end

  def test_dispatch_errors_and_method_negotiation
    app = Hamster::Application.new(routes: Routes)
    assert_equal [200, "12"], response(app, "GET", "/items/12")
    assert_equal 404, response(app, "GET", "/missing")[0]
    result = app.call("REQUEST_METHOD" => "POST", "PATH_INFO" => "/items/12")
    assert_equal 405, result[0]
    assert_equal "GET", result[1]["allow"]
    status, body = response(app, "GET", "/broken")
    assert_equal 500, status
    refute_includes body, "private error detail"
  end

  def response(app, method, path)
    result = app.call("REQUEST_METHOD" => method, "PATH_INFO" => path)
    [result[0], result[2].join]
  end
end
