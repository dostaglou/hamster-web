module FrontendDemo
  module Routes
    module Posts
      module Index
        class Action < Hamster::Action::Base
          def call
            form = Hamster::View::Form.new(action: "/posts", csrf_token: Store.token)
            respond(view: "posts/index", locals: {form: form, posts: Store.all, token: Store.token})
          end
        end
      end
    end
  end
end
