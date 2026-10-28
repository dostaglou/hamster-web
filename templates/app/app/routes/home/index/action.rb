# frozen_string_literal: true
module __APP_MODULE__
  module Routes
    module Home
      module Index
        class Action < Hamster::Action::Base
          def call
            respond(view: "home/index")
          end
        end
      end
    end
  end
end
