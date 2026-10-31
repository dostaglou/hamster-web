require "securerandom"
module FrontendDemo
  class PostInput < Hamster::Form
    field :title, required: true, max_length: 80
  end
  class Store
    def self.setup
      @rows = {}
      @sequence = 0
      @lock = Mutex.new
      @token = SecureRandom.hex(32)
    end
    def self.token; @token; end
    def self.all; @lock.synchronize { @rows.sort.map { |id, title| [id, title] } }; end
    def self.find(id); @lock.synchronize { @rows[id] }; end
    def self.create(title)
      @lock.synchronize do
        @sequence += 1
        @rows[@sequence.to_s] = title
      end
    end
    def self.update(id, title); @lock.synchronize { @rows[id] = title if @rows.key?(id) }; end
    def self.destroy(id); @lock.synchronize { @rows.delete(id) }; end
  end
  module Mutation
    extend Hamster::Action::Callbacks
    before_action :verify_csrf
    def verify_csrf
      respond(body: "Forbidden", status: :forbidden) unless context.valid_csrf?(Store.token)
    end
    def finish_mutation
      return redirect_to("/posts") unless context.format == :turbo_stream
      list = Hamster::View.render("posts/shared/list", {posts: Store.all, token: Store.token}, layout: nil)
      respond(body: Hamster::Turbo.stream("update", "posts", list), type: :turbo_stream)
    end
  end
  Store.setup
end
