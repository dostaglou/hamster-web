module FrontendDemo
  module Routes
    module Posts
      module Update
        class Action < Hamster::Action::Base
          include Mutation
          def call
            id = context.params.fetch("id")
            return respond(body: "Missing", status: :not_found) unless Store.find(id)
            input = PostInput.new(context.form)
            unless input.valid?
              form = Hamster::View::Form.new(action: "/posts/#{id}", method: "PATCH", csrf_token: Store.token, values: input.values, errors: input.errors)
              return respond(view: "posts/edit", locals: {form: form}, status: :unprocessable_entity)
            end
            Store.update(id, input[:title])
            redirect_to("/posts")
          end
        end
      end
    end
  end
end
