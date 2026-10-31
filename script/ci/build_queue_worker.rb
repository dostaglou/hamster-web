require "tmpdir"
require "open3"
require "hamster/build/jobs"
target = File.expand_path(ARGV.fetch(0))
driver = File.expand_path(ARGV.fetch(1))
library = File.expand_path("../..", File.dirname($LOADED_FEATURES.find { |path| path.end_with?("/hamster/build/jobs.rb") }))
source = File.read(File.join(__dir__, "queue_jobs.rb"))
Dir.mktmpdir("hamster-worker-build") do |root|
  entry = File.join(root, "entry.rb")
  File.write(entry, "require \"queue_worker_fixture\"\n" + Hamster::Build::Jobs.compile([source]))
  output, status = Open3.capture2e(ENV.fetch("SPINEL", "spinel"), entry, "--require-gate", "-I", library, "-I", driver, "-I", File.expand_path(__dir__), "-o", target)
  raise output unless status.success?
  puts output
end
