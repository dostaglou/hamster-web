require "minitest/autorun"
require_relative "../lib/hamster/testing"
require_relative "../lib/hamster/data"
class FormTest < Hamster::Testing::Test
  class Input < Hamster::Form
    field :title, required: true, min_length: 2, max_length: 20
    field :count, type: :integer
    field :published, type: :boolean
    field :password, sensitive: true
  end
  class Post < Hamster::Table
    table :posts
    column :title, type: :text, write: :both
    column :secret, type: :text, enabled: false, write: :both
  end
  class PostInput < Hamster::Form
    model Post
    field :title, required: true
  end
  class BadInput < Hamster::Form
    model Post
    field :secret
  end
  class Create < Hamster::Action::Base
    def call
      input = Input.new(context.form)
      return redirect_to("/posts") if input.valid?
      form = Hamster::View::Form.new(action: "/posts", csrf_token: "explicit-token", values: input.values, errors: input.errors)
      body = Hamster::HTML.join([form.start, form.error_summary, form.label(:title), form.text(:title), form.error(:title), form.submit("Save"), form.finish])
      body = Hamster::Turbo.stream("replace", "post_form", body) if context.format == :turbo_stream
      respond(body: body, status: :unprocessable_entity, type: context.format == :turbo_stream ? :turbo_stream : :html)
    end
  end
  class Routes < Hamster::Routing::Base
    post "/posts", to: Create
    patch "/posts", to: Create, as: :update_post
  end
  def test_explicit_coercion_error_categories_and_isolation
    input = Input.new(title: "Hello", count: "12", published: "false", password: "private")
    assert input.valid?
    assert_equal({title: "Hello", count: 12, published: false, password: "private"}, input.attributes)
    refute input.values.key?("password")
    assert_equal ["missing"], Input.new.error_codes["title"]
    assert_equal ["blank"], Input.new(title: " ").error_codes["title"]
    malformed = Input.new(title: "H", count: "twelve", unknown: "private")
    assert_equal ["malformed"], malformed.error_codes["count"]
    assert_equal ["too_short"], malformed.error_codes["title"]
    assert_raises(ArgumentError) { malformed.attributes }
    input.reject(:title)
    assert_equal ["unauthorized"], input.error_codes["title"]
    assert Input.new(title: "Other").valid?
    assert_raises(Hamster::Read::DisabledColumnError) { BadInput.new(secret: "x") }
    assert PostInput.new(title: "Allowed").valid?
  end
  def test_csrf_controls_are_explicit_and_never_mass_assigned
    input = Input.new(title: "Hello", csrf_token: "token", _method: "POST")
    assert input.valid?
    refute input.attributes.key?(:csrf_token)
    env = {"HTTP_ORIGIN" => "https://example.test", "HTTP_HOST" => "example.test", "rack.url_scheme" => "https", "HTTP_X_CSRF_TOKEN" => "token"}
    assert Hamster::Context.new(env).valid_csrf?("token")
    refute Hamster::Context.new(env.merge("HTTP_ORIGIN" => "https://evil.test")).valid_csrf?("token")
    refute Hamster::Context.new(env).valid_csrf?("wrong")
  end

  def test_html_and_turbo_invalid_submissions_and_redirect
    client = Hamster::Testing::Client.new(Hamster::Application.new(routes: Routes))
    ["text/html", "text/vnd.turbo-stream.html"].each do |accept|
      response = client.post("/posts", form: {title: '<script>bad</script>' * 3}, headers: {"Accept" => accept})
      assert_status 422, response
      refute_includes response.body, "<script>"
      assert_includes response.body, "&lt;script&gt;"
      assert_includes response.body, "csrf_token"
      assert_includes response.body, "<turbo-stream" if accept.include?("turbo-stream")
    end
    assert_status :see_other, client.post("/posts", form: {title: "Valid"})
    assert_status :see_other, client.post("/posts", form: {title: "Valid", _method: "PATCH"})
  end
end
