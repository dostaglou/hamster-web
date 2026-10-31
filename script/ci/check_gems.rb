# Verify versions, isolated resolution, and exact local candidate provenance.
require "rubygems"
require "rubygems/package"
require "digest"
require "tmpdir"

expected = {"hamster-web" => ARGV.fetch(0), "spinel-spinner" => ARGV.fetch(1)}
specs = expected.to_h do |name, version|
  spec = Gem::Specification.find_by_name(name, "= #{version}")
  path = File.realpath(spec.full_gem_path)
  abort "#{name} resolved outside isolated gems: #{path}" unless path.start_with?(File.realpath(ENV.fetch("GEM_HOME")) + "/")
  puts "#{name} #{spec.version}: #{path}"
  [name, spec]
end
ARGV.drop(2).each do |candidate|
  package = Gem::Package.new(candidate)
  spec = package.spec
  abort "Unexpected candidate #{spec.name} #{spec.version}" unless expected[spec.name] == spec.version.to_s
  installed = specs.fetch(spec.name)
  digest = Digest::SHA256.file(candidate).hexdigest
  cache = File.join(installed.base_dir, "cache", "#{spec.full_name}.gem")
  abort "Candidate archive mismatch: #{spec.name}" unless Digest::SHA256.file(cache).hexdigest == digest
  Dir.mktmpdir("candidate-provenance-") do |directory|
    package.extract_files(directory)
    spec.files.each do |file|
      source = File.join(directory, file)
      next unless File.file?(source)
      target = File.join(installed.full_gem_path, file)
      abort "Candidate file mismatch: #{spec.name}/#{file}" unless File.file?(target) && Digest::SHA256.file(target).hexdigest == Digest::SHA256.file(source).hexdigest
    end
  end
  puts "#{spec.name} candidate SHA256: #{digest} (installed files verified)"
end
