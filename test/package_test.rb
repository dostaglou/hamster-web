require "minitest/autorun"
require "tmpdir"
require "open3"
require "rbconfig"
require "rubygems/package"
require_relative "../lib/hamster/web/version"

class PackageTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_built_package_generates_a_complete_app_without_repository_sources
    contract = File.readlines(File.join(ROOT, "script/ci/versions.env")).filter_map do |line|
      line.strip.split("=", 2) if line.match?(/\A[A-Z_]+=/)
    end.to_h
    Dir.mktmpdir do |directory|
      gem_path = File.join(directory, "hamster-web.gem")
      output, status = Open3.capture2e(RbConfig.ruby, "-S", "gem", "build", "hamster-web.gemspec", "--output", gem_path, chdir: ROOT)
      assert status.success?, output
      package = Gem::Package.new(gem_path)
      spec = package.spec
      assert_equal contract.fetch("HAMSTER_VERSION"), spec.version.to_s
      dependency = spec.runtime_dependencies.find { |entry| entry.name == "spinel-spinner" }
      refute_nil dependency
      assert_equal "= #{contract.fetch('SPINNER_VERSION')}", dependency.requirement.to_s
      refute spec.dependencies.any? { |entry| entry.name == "spinner" }
      unpacked = File.join(directory, "unpacked")
      package.extract_files(unpacked)
      output, status = Open3.capture2e(
        {"RUBYLIB" => nil, "RUBYOPT" => nil}, RbConfig.ruby,
        "-I", File.join(unpacked, "lib"), File.join(unpacked, "exe/hamster"), "new", "SmokeApp", chdir: directory
      )
      assert status.success?, output
      app = File.join(directory, "smoke_app")
      %w[bin/server bin/hamster config/application.rb config/commands.rb config/database.rb config/manifest.rb spin.toml spin.lock].each do |file|
        assert File.file?(File.join(app, file)), "Missing packaged template/generated file: #{file}"
      end
      assert File.executable?(File.join(app, "bin/hamster"))
      gemfile = File.read(File.join(app, "Gemfile"))
      assert_includes gemfile, %(gem "hamster-web", "= #{spec.version}", require: "hamster/web")
      assert_includes gemfile, %(gem "spinel-spinner", "= #{contract.fetch('SPINNER_VERSION')}", require: "spinner")
      assert_includes File.read(File.join(app, "spin.lock")), contract.fetch("PG_REVISION")
      assert_includes File.read(File.join(app, "bin/server")), 'require "spinner"'
      assert_includes File.read(File.join(app, "app/routes/home/index/view.html.erb")), "Welcome to smoke_app"
      refute_match(/__APP_NAME__|__APP_MODULE__|__HAMSTER_VERSION__/, gemfile)
    end
  end
end
