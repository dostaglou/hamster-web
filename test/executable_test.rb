require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"

class ExecutableTest < Minitest::Test
  def test_global_executable_delegates_before_loading_the_installed_framework
    executable = File.expand_path("../exe/hamster", __dir__)
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      FileUtils.mkdir_p(File.join(root, "bin"))
      FileUtils.mkdir_p(File.join(root, "app/routes"))
      File.write(File.join(root, "config/hamster.json"), "{}")
      File.write(File.join(root, "bin/hamster"), 'puts "app binstub: " + ARGV.join(" ")')
      output, status = Open3.capture2e(RbConfig.ruby, "--disable-gems", executable, "build", chdir: File.join(root, "app/routes"))
      assert status.success?, output
      assert_equal "app binstub: build\n", output
    end
  end
end
