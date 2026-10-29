require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "rbconfig"

class CLIToolsTest < Minitest::Test
  def test_missing_tool_diagnostics_identify_the_tool_and_next_step
    executable = File.expand_path("../exe/hamster", __dir__)
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      File.write(File.join(root, "config/hamster.json"), JSON.generate(name: "smoke_app"))
      File.write(File.join(root, "spin.toml"), "[dependencies]\n")
      {"setup" => "Bundler", "build" => "SPINEL", "db:create" => "setup", "db:migrate" => "setup"}.each do |command, hint|
        output, status = Open3.capture2e(
          {"PATH" => File.join(root, "missing"), "SPINEL" => File.join(root, "missing-spinel")},
          RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), executable, command, chdir: root
        )
        refute status.success?, output
        assert_includes output, "Required executable"
        assert_includes output, hint
      end
    end
  end
end
