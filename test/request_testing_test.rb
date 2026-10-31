require "minitest/autorun"
require_relative "../lib/hamster/testing"
require_relative "../lib/hamster/test_database"
require_relative "../lib/hamster/cli"
require_relative "../lib/hamster/generators/runner"
class RequestTestingTest < Hamster::Testing::Test
  class Echo < Hamster::Action::Base
    def call; respond(json: context.json); end
  end
  class Upload < Hamster::Action::Base
    def call
      file = context.uploads.fetch("file").first
      send_data(file.io, filename: file.filename)
    end
  end
  class Routes < Hamster::Routing::Base
    post "/json", to: Echo
    post "/upload", to: Upload
  end
  def test_json_and_binary_multipart_roundtrips_close_resources
    client = Hamster::Testing::Client.new(Hamster::Application.new(routes: Routes))
    response = client.post("/json", json: {"message" => "日本語"})
    assert_status :ok, response
    assert_json({"message" => "日本語"}, response)
    bytes = (0..255).to_a.pack("C*") * 1024
    response = client.multipart("/upload", files: {"file" => {filename: "binary.bin", data: bytes}})
    assert_equal bytes, response.body
    assert_content_type "application/octet-stream", response
    assert_status :not_found, client.get("/missing")
    assert_status :method_not_allowed, client.get("/json")
  end
  def test_stream_close_on_head_and_iteration_failure
    stream = Object.new
    def stream.each; raise "must not iterate"; end
    def stream.close; @closed = true; end
    def stream.closed?; @closed; end
    app = ->(_env) { [200, {}, stream] }
    assert_equal "", Hamster::Testing::Client.new(app).head("/").body
    assert stream.closed?
    assert_raises(RuntimeError) { Hamster::Testing::Client.new(app).get("/") }
    assert stream.closed?
  end
  def test_database_guards_and_generated_endpoint_tests
    base = {"HAMSTER_ENV" => "test", "HAMSTER_TEST_DATABASE" => "1", "TEST_DATABASE_USERNAME" => "tester"}
    first = Hamster::Testing::TestDatabase.configuration(base)
    second = Hamster::Testing::TestDatabase.configuration(base)
    refute_equal first.database, second.database
    [base.merge("HAMSTER_ENV" => "production"), base.merge("DATABASE_NAME" => "production"),
     base.merge("TEST_DATABASE_HOST" => "production.internal"), base.merge("HAMSTER_TEST_DATABASE" => "0")].each do |env|
      assert_raises(ArgumentError) { Hamster::Testing::TestDatabase.configuration(env) }
    end
    Dir.mktmpdir do |parent|
      capture_io { Dir.chdir(parent) { Hamster::Generator.create("RequestApp") } }
      root = File.join(parent, "request_app")
      capture_io { Hamster::Generators::Runner.run(root, %w[endpoint posts/show --view --path /posts/:id]) }
      Dir.chdir(root) do
        output, = capture_io { assert_equal 0, Hamster::CLI.run(%w[test --json]) }
        assert JSON.parse(output)["valid"]
        path = File.join(root, "app/routes/posts/show/action.rb")
        File.write(path, File.read(path).sub('respond(view: "posts/show")', 'respond(body: "broken")'))
        Hamster::Build::Manifest.generate(root)
        output, = capture_io { assert_equal 1, Hamster::CLI.run(%w[test test/requests --json]) }
        refute JSON.parse(output)["valid"]
      end
    end
  end
end
