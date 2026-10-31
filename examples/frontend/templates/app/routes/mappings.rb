# frozen_string_literal: true
module FrontendDemo
  module Routes
    class Mappings < Hamster::Routing::Base
      get "/", to: Home::Index::Action, as: :root
      get "/up", to: Up::Index::Action, as: :up
      get "/posts", to: Posts::Index::Action, as: :posts
      post "/posts", to: Posts::Create::Action, as: :create_post
      get "/posts/:id/edit", to: Posts::Edit::Action, as: :edit_post
      patch "/posts/:id", to: Posts::Update::Action, as: :update_post
      delete "/posts/:id", to: Posts::Destroy::Action, as: :destroy_post
    end
  end
end
