require "minitest/autorun"
require "tmpdir"
require_relative "../lib/hamster/cli"

class GeneratorTest < Minitest::Test
  def test_names_templates_and_collision_handling
    Dir.mktmpdir do |root|
      Dir.chdir(root) do
        Hamster::Generator.create("TestApp")
        config = File.read("test_app/config/application.rb")
        assert_includes config, "module TestApp"
        assert File.executable?("test_app/bin/hamster")
        assert_empty Hamster::Build::Manifest.check(File.join(root, "test_app"))
        assert_raises(ArgumentError) { Hamster::Generator.create("TestApp") }
        assert_equal config, File.read("test_app/config/application.rb")
      end
    end
  end

  def test_rejects_paths_and_reserved_names
    ["../escape", "", "Hamster", "bad-name"].each do |name|
      assert_raises(ArgumentError) { Hamster::Generator.create(name) }
    end
  end
end
