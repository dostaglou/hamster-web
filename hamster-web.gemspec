# frozen_string_literal: true

require_relative "lib/hamster/web/version"

Gem::Specification.new do |spec|
  spec.name = "hamster-web"
  spec.version = Hamster::Web::VERSION
  spec.authors = ["Dillon Wyatt"]
  spec.email = ["dostaglou@gmail.com"]
  spec.summary = "A Spinel web framework and application generator"
  spec.description = "Hamster provides a compiled Spinel web runtime and a CLI for generating applications."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.files = Dir.chdir(__dir__) do
    Dir.glob("{exe,lib,templates}/**/*", File::FNM_DOTMATCH).select { |path| File.file?(path) } +
      %w[README.md LICENSE.txt]
  end
  spec.bindir = "exe"
  spec.executables = ["hamster"]
  spec.require_paths = ["lib"]
  spec.add_dependency "spinel-spinner", "= 0.1.0.pre.1"
end
