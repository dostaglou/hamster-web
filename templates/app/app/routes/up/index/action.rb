# frozen_string_literal: true
module __APP_MODULE__
  module Routes
    module Up
      module Index
        class Action < Hamster::Action::Base
          def call
            respond(body: "OK\n", headers: {"content-type" => "text/plain; charset=utf-8"})
          end
        end
      end
    end
  end
end
