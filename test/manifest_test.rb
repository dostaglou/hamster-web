require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/hamster/build/manifest"

class ManifestTest < Minitest::Test
  def test_generation_and_freshness
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      FileUtils.mkdir_p(File.join(root, "app/routes/home"))
      view = File.join(root, "app/routes/home/view.html.erb")
      File.write(view, "<h1>Hello</h1>")
      Hamster::Build::Manifest.generate(root)
      assert_empty Hamster::Build::Manifest.check(root)
      File.write(view, "<h1>Changed</h1>")
      refute_empty Hamster::Build::Manifest.check(root)
      Hamster::Build::Manifest.generate(root)
      assert_empty Hamster::Build::Manifest.check(root)
      registry = File.join(root, "config/view_registry.rb")
      assert_includes File.read(registry), "Changed"
    end
  end
end
