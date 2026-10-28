require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/hamster/build/postgres_compatibility"

class PostgresCompatibilityTest < Minitest::Test
  def test_fresh_vendor_patch_is_idempotent_and_fails_closed_on_unknown_source
    patch = Hamster::Build::PostgresCompatibility
    Dir.mktmpdir do |root|
      package = File.join(root, "vendor/packages/pg-0.2.0")
      FileUtils.mkdir_p(File.join(package, "pg"))
      File.write(File.join(package, ".spin-sha"), patch::REVISION)
      path = File.join(package, "pg/client.rb")
      File.write(path, patch::COPIES.join("\n") + "\n")
      patch.apply(root)
      fixed = File.read(path)
      assert_equal 3, fixed.scan(/\.dup/).length
      patch.apply(root)
      assert_equal fixed, File.read(path)
      File.write(path, "unexpected source\n")
      assert_raises(RuntimeError) { patch.apply(root) }
      assert_equal "unexpected source\n", File.read(path)
      File.write(File.join(package, ".spin-sha"), "different revision")
      assert_raises(RuntimeError) { patch.apply(root) }
    end
  end
end
