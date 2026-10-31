module SmokeApp
  class JsonEcho < Hamster::Action::Base
    def call
      respond(json: context.json, status: :created)
    end
  end
end
