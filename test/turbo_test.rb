require "minitest/autorun"
require_relative "../lib/hamster/web"
class TurboTest < Minitest::Test
  def test_streams_and_frames_escape_untrusted_content
    frame = Hamster::Turbo.frame("posts", '<script>bad</script>')
    assert_includes frame.to_s, "&lt;script&gt;"
    Hamster::Turbo::ACTIONS.each do |action|
      stream = Hamster::Turbo.stream(action, "post_1", action == "remove" ? nil : frame)
      assert_includes stream.to_s, "action=\"#{action}\""
      assert_includes stream.to_s, 'target="post_1"'
      assert_includes stream.to_s, "<template>" unless action == "remove"
    end
    assert_raises(ArgumentError) { Hamster::Turbo.frame('x" onclick="bad', "x") }
    assert_raises(ArgumentError) { Hamster::Turbo.stream("eval", "x") }
    response = Hamster::Http.response(422, Hamster::Turbo.stream("replace", "post_1", "Invalid"), type: :turbo_stream)
    assert_equal 422, response[0]
    assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response[1]["content-type"]
  end
end
