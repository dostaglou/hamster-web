# frozen_string_literal: true
require_relative "generators/runner"

module Hamster
  # Compatibility entrypoint for existing callers.
  EndpointGenerator = Generators::Runner
end
