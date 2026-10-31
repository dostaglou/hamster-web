require "json"
require "open3"
require "fileutils"
require "rbconfig"
root = File.expand_path("../../..", __FILE__)
artifacts = File.join(root, "tmp/activejob-spike")
gems = File.join(artifacts, "gems")
FileUtils.mkdir_p(gems)
env = {"GEM_HOME" => gems, "GEM_PATH" => gems}
versions = JSON.parse(File.read(File.join(__dir__, "active_job_versions.json")))
if ARGV == ["--install"]
  versions.each do |name, version|
    raise "Cannot install #{name}" unless system(env, "gem", "install", name, "--version", version, "--ignore-dependencies", "--no-document", "--install-dir", gems)
  end
elsif !ARGV.empty?
  abort "Usage: run_active_job_spike.rb [--install]"
end
probe = File.join(__dir__, "active_job_probe.rb")
output, status = Open3.capture2e(env, RbConfig.ruby, probe)
File.write(File.join(artifacts, "cruby.log"), output)
raise "CRuby control failed: #{output}" unless status.success?
source = 'require "json"; puts Gem::Specification.map { |s| {name: s.name, version: s.version.to_s, paths: s.full_require_paths} }.to_json'
specs, status = Open3.capture2e(env, RbConfig.ruby, "-e", source)
raise specs unless status.success?
entries = JSON.parse(specs)
versions.each { |name, version| raise "Incorrect dependency #{name}" unless entries.any? { |s| s["name"] == name && s["version"] == version } }
# Prefer Spinel's native standard-library bindings; use gemspec require paths
# for the actual Active Job dependency graph (concurrent-ruby has a nested lib).
names = %w[activejob activesupport globalid concurrent-ruby tzinfo i18n connection_pool]
args = [ENV.fetch("SPINEL", "spinel"), probe, "--require-gate"]
entries.select { |s| names.include?(s["name"]) }.sort_by { |s| s["name"] }.each { |s| s["paths"].each { |p| args.concat(["-I", p]) } }
args.concat(["-o", File.join(artifacts, "native-probe")])
output, status = Open3.capture2e(*args)
File.write(File.join(artifacts, "native.log"), output)
File.write(File.join(artifacts, "command.json"), JSON.pretty_generate(args))
puts "CRuby control: passed; native compile: #{status.success? ? 'passed' : 'blocked'}"
puts output
# The spike records either result; it is not a gate that claims compatibility.
