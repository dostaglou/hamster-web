require "tmpdir"
require "open3"
require "hamster/build/manifest"
name = ARGV.fetch(0)
abort "Use jobs or storage" unless %w[jobs storage].include?(name)
source = File.read(File.join(__dir__, "#{name}_native_fixture.rb"))
source += "\n" + Hamster::Build::Jobs.compile([source]) if name == "jobs"
loaded = $LOADED_FEATURES.find { |path| path.end_with?("/hamster/build/manifest.rb") }
library = File.expand_path("../..", File.dirname(loaded))
Dir.mktmpdir("hamster-native-fixture") do |root|
  entry, binary = File.join(root, "probe.rb"), File.join(root, "probe")
  File.write(entry, source)
  output, status = Open3.capture2e(ENV.fetch("SPINEL", "spinel"), entry, "--require-gate", "-I", library, "-o", binary)
  raise output unless status.success?
  args = name == "storage" ? [File.join(root, "blobs")] : []
  output, status = Open3.capture2e(binary, *args)
  raise output unless status.success?
  puts output
end
