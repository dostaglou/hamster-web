# Compile this fixture with the Hamster and Spinner library directories on -I.
require "spinner"
require "hamster/web"

class Home < Hamster::Action::Base
  def call
    respond(body: "Hello from Hamster")
  end
end

class Routes < Hamster::Routing::Base
  get "/", to: Home
end

application = Hamster::Application.new(routes: Routes)
begin
  Spinner::Server.new(application, host: "127.0.0.1", port: 4000).run
ensure
  application.shutdown
end
