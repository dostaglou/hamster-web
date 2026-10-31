require_relative "test_helper"
class HomeTest < AppRequestTest
  def test_welcome
    response = client.get("/")
    assert_status :ok, response
    assert_html "Welcome to __APP_NAME__", response
  end
end
