require "minitest/autorun"
require "tmpdir"
require "open3"
require "json"
require "rbconfig"
require_relative "../lib/hamster/cli"

class GeneratedHealthTest < Minitest::Test
  def test_liveness_avoids_database_checkout_and_keeps_normal_route_dispatch
    Dir.mktmpdir do |directory|
      Dir.chdir(directory) { Hamster::Generator.create("HealthApp") }
      script = <<~RUBY
        require "hamster/web"
        require #{File.join(directory, 'health_app/config/manifest').inspect}
        class OfflineDatabase
          attr_reader :checkouts, :closed
          def initialize; @checkouts = 0; end
          def with_connection
            @checkouts += 1
            raise "offline"
          end
          def shutdown; @closed = true; end
        end
        database = OfflineDatabase.new
        app = HealthApp::Application.new(routes: HealthApp::Routes::Mappings, database: database)
        up = app.call("PATH_INFO" => "/up", "REQUEST_METHOD" => "GET")
        method = app.call("PATH_INFO" => "/up", "REQUEST_METHOD" => "POST")
        health_checkouts = database.checkouts
        home = app.call("PATH_INFO" => "/", "REQUEST_METHOD" => "GET")
        app.shutdown
        require "json"
        puts JSON.generate(up: up, method: method, health_checkouts: health_checkouts,
                           home: home, total_checkouts: database.checkouts, closed: database.closed)
      RUBY
      output, status = Open3.capture2e(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script)
      assert status.success?, output
      result = JSON.parse(output)
      assert_equal [200, "OK\n"], [result.fetch("up")[0], result.fetch("up")[2].join]
      assert_equal "text/plain; charset=utf-8", result.fetch("up")[1]["content-type"]
      assert_equal "no-store", result.fetch("up")[1]["cache-control"]
      assert_equal 405, result.fetch("method")[0]
      assert_equal "GET", result.fetch("method")[1]["allow"]
      assert_equal 0, result.fetch("health_checkouts")
      assert_equal 500, result.fetch("home")[0]
      assert_equal 1, result.fetch("total_checkouts")
      assert result.fetch("closed")
    end
  end
end
