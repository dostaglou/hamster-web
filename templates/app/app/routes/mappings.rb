# frozen_string_literal: true
module __APP_MODULE__
  module Routes
    class Mappings < Hamster::Routing::Base
      get "/", to: Home::Index::Action, as: :root
      get "/up", to: Up::Index::Action, as: :up
    end
  end
end
