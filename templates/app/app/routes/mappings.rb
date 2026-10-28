# frozen_string_literal: true
module __APP_MODULE__
  module Routes
    class Mappings < Hamster::Routing::Base
      get "/", to: Home::Index::Action, as: :root
    end
  end
end
