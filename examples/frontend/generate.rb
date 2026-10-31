require "fileutils"
require_relative "../../lib/hamster/cli"
parent = File.expand_path(ARGV.fetch(0, "../../tmp"), __dir__)
FileUtils.mkdir_p(parent)
Dir.chdir(parent) { Hamster::Generator.create("FrontendDemo") }
root = File.join(parent, "frontend_demo")
FileUtils.cp_r(File.join(__dir__, "templates", "."), root)
Hamster::Build::Manifest.generate(root)
puts "Frontend demo: #{root}"
