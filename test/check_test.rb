require "minitest/autorun"
require_relative "../lib/hamster/cli"
require_relative "../lib/hamster/check"
class CheckTest < Minitest::Test
  def app
    Dir.mktmpdir do |parent|
      capture_io { Dir.chdir(parent) { Hamster::Generator.create("CheckApp") } }
      yield File.join(parent, "check_app")
    end
  end
  def test_quick_check_is_read_only_and_locates_stale_manifest
    app do |root|
      assert Hamster::Check.run(root)["valid"]
      path = File.join(root, "config/manifest.rb")
      File.write(path, "# stale\n")
      report = Hamster::Check.run(root)
      refute report["valid"]
      assert_equal "manifest.stale", report["diagnostics"].first["code"]
      assert_equal "config/manifest.rb", report["diagnostics"].first["path"]
      assert_equal "# stale\n", File.read(path)
      File.write(File.join(root, "app/broken.rb"), "class\n")
      assert_equal "ruby.syntax", Hamster::Check.run(root)["diagnostics"].first["code"]
    end
  end
  def test_missing_views_and_unresolved_callbacks_are_actionable
    app do |root|
      path = File.join(root, "app/routes/home/index/action.rb")
      File.write(path, File.read(path).sub('home/index', 'home/missing'))
      Hamster::Build::Manifest.generate(root)
      report = Hamster::Check.run(root)
      refute report["valid"]
      assert report["diagnostics"].any? { |d| d["code"] == "view.missing" && d["path"].end_with?("action.rb") && d["line"] > 0 }
    end
  end
  def test_json_exit_status_and_explicit_hooks
    app do |root|
      Dir.chdir(root) do
        output, = capture_io { assert_equal 0, Hamster::CLI.run(%w[check --json]) }
        assert JSON.parse(output)["valid"]
        refute File.exist?(".githooks")
        system("git", "init", "--quiet")
        capture_io { assert_equal 0, Hamster::Check.install_hooks(root, ["--pre-push"]) }
        assert File.executable?(".githooks/pre-commit")
        assert_includes File.read(".githooks/pre-push"), "--full"
        File.write(".githooks/pre-commit", "custom")
        assert_raises(RuntimeError) { Hamster::Check.install_hooks(root, []) }
      end
    end
  end
end
