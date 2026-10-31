module FrontendDemo
  module Routes
    module Posts
      module Edit
        class Action < Hamster::Action::Base
          def call
            id = context.params.fetch("id")
            title = Store.find(id)
            return respond(body: "Missing", status: :not_found) unless title
            form = Hamster::View::Form.new(action: "/posts/#{id}", method: "PATCH", csrf_token: Store.token, values: {title: title})
            respond(view: "posts/edit", locals: {form: form})
          end
        end
      end
    end
  end
end
