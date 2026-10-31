require "hamster/testing"
require_relative "../config/manifest"
Hamster::View.configure(site_name: "__APP_NAME__", routes: __APP_MODULE__::Routes::Mappings)
class AppRequestTest < Hamster::Testing::Test
  def client
    @client ||= Hamster::Testing::Client.new(__APP_MODULE__::Application.new(routes: __APP_MODULE__::Routes::Mappings, database: nil))
  end
end
