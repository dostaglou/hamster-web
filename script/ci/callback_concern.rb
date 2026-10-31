module SmokeApp
  module Audit
    extend Hamster::Action::Callbacks
    before_action :tag_request
    after_action :audit
    def tag_request
      @marker = "yes"
      nil
    end
    def audit(response)
      response[1]["audit"] = @marker
      nil
    end
  end
end
