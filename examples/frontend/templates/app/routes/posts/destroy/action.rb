module FrontendDemo
  module Routes
    module Posts
      module Destroy
        class Action < Hamster::Action::Base
          include Mutation
          def call
            Store.destroy(context.params.fetch("id"))
            finish_mutation
          end
        end
      end
    end
  end
end
