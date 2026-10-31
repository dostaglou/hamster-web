module FrontendDemo
  module Routes
    module Posts
      module Create
        class Action < Hamster::Action::Base
          include Mutation
          def call
            input = PostInput.new(context.form)
            unless input.valid?
              form = Hamster::View::Form.new(action: "/posts", csrf_token: Store.token, values: input.values, errors: input.errors)
              return respond(view: "posts/index", locals: {form: form, posts: Store.all, token: Store.token}, status: :unprocessable_entity)
            end
            Store.create(input[:title])
            finish_mutation
          end
        end
      end
    end
  end
end
