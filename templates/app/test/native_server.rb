# Native test entrypoint: no live database or application boot side effects.
require "spinner"
require "hamster/web"
require_relative "../config/manifest"
application = __APP_MODULE__::Application.new(routes: __APP_MODULE__::Routes::Mappings, database: nil)
begin
  Spinner::Server.new(application, host: "127.0.0.1", port: ENV.fetch("PORT", "0").to_i).run
ensure
  application.shutdown
end
