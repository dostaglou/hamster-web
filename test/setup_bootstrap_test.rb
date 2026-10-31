require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
class SetupBootstrapTest < Minitest::Test
  def test_only_setup_installs_missing_dependencies_before_loading_bundle
    Dir.mktmpdir do |root|
      %w[lib/bundler lib/hamster bin].each { |path| FileUtils.mkdir_p(File.join(root, path)) }
      File.write(File.join(root, "lib/bundler.rb"), 'module Bundler; def self.with_unbundled_env; yield; end; end')
      File.write(File.join(root, "lib/bundler/setup.rb"), 'abort "bundle unresolved" unless File.file?(File.join(ENV.fetch("BOOTSTRAP_TEST_DIR"), "installed"))')
      File.write(File.join(root, "lib/hamster/cli.rb"), 'module Hamster; module CLI; def self.run(args); puts "CLI #{args.join(" ")}"; 0; end; end; end')
      File.write(File.join(root, "bin/bundle"), <<~SOURCE)
        #!#{RbConfig.ruby}
        root = ENV.fetch("BOOTSTRAP_TEST_DIR")
        File.open(File.join(root, "calls"), "a") { |file| file.puts ARGV.first }
        if ARGV.first == "install"
          File.write(File.join(root, "installed"), "yes")
          exit 0
        end
        exit(File.file?(File.join(root, "installed")) ? 0 : 1)
      SOURCE
      File.chmod(0755, File.join(root, "bin/bundle"))
      env = {"RUBYOPT" => nil, "RUBYLIB" => File.join(root, "lib"), "PATH" => File.join(root, "bin"), "BOOTSTRAP_TEST_DIR" => root}
      binstub = File.expand_path("../templates/app/bin/hamster", __dir__)
      output, status = Open3.capture2e(env, RbConfig.ruby, binstub, "routes", chdir: root)
      refute status.success?
      assert_includes output, "bundle unresolved"
      refute File.exist?(File.join(root, "calls"))
      output, status = Open3.capture2e(env, RbConfig.ruby, binstub, "setup", chdir: root)
      assert status.success?, output
      assert_equal "CLI setup\n", output
      assert_equal "check\ninstall\n", File.read(File.join(root, "calls"))
      File.unlink(File.join(root, "calls"))
      output, status = Open3.capture2e(env, RbConfig.ruby, binstub, "setup", chdir: root)
      assert status.success?, output
      assert_equal "check\n", File.read(File.join(root, "calls"))
    end
  end
end
