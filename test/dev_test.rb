require "minitest/autorun"
require "stringio"
require_relative "../lib/hamster/cli"
require_relative "../lib/hamster/dev"
class DevTest < Minitest::Test
  def test_rebuild_failure_recovery_changes_during_build_and_process_cleanup
    Dir.mktmpdir do |parent|
      capture_io { Dir.chdir(parent) { Hamster::Generator.create("DevApp") } }
      root = File.join(parent, "dev_app")
      binary = File.join(root, "bin/dev_app-server")
      File.write(binary, "#!/bin/sh\ntrap 'exit 0' TERM\nwhile :; do sleep 0.1; done\n")
      File.chmod(0755, binary)
      output = StringIO.new
      fail_build = false
      edit_during_build = false
      build = lambda do
        raise "compiler.rb:12: deliberate compile failure" if fail_build
        if edit_during_build
          File.write(File.join(root, "app/changed.rb"), "# changed while building\n")
        end
        Hamster::Build::Manifest.generate(root)
      end
      runner = Hamster::Dev::Runner.new(root, build: build, output: output, drain_timeout: 2)
      assert runner.rebuild(runner.snapshot)
      pid = runner.pid
      assert_equal :running, runner.state
      runner.stop_server
      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
      fail_build = true
      refute runner.rebuild(runner.snapshot)
      assert_equal :failed, runner.state
      assert_nil runner.pid
      assert_includes output.string, "compiler.rb:12"
      fail_build = false
      edit_during_build = true
      refute runner.rebuild(runner.snapshot)
      assert_nil runner.pid
      edit_during_build = false
      assert runner.rebuild(runner.snapshot)
      runner.stop_server
      assert_nil runner.pid
    ensure
      runner&.stop_server
    end
  end
  def test_watcher_debounces_edits_and_recovers_after_invalid_source
    Dir.mktmpdir do |parent|
      capture_io { Dir.chdir(parent) { Hamster::Generator.create("LoopApp") } }
      root = File.join(parent, "loop_app")
      binary = File.join(root, "bin/loop_app-server")
      File.write(binary, "#!/bin/sh\ntrap 'exit 0' TERM\nwhile :; do sleep 0.1; done\n")
      File.chmod(0755, binary)
      builds = 0
      build = -> { builds += 1; Hamster::Build::Manifest.generate(root) }
      runner = Hamster::Dev::Runner.new(root, build: build, output: StringIO.new, interval: 0.01, debounce: 0.04, drain_timeout: 2)
      failure = nil
      editor = Thread.new do
        begin
          wait = ->(&condition) { Timeout.timeout(5) { sleep 0.01 until condition.call } }
          wait.call { runner.state == :running }
          file = File.join(root, "app/change.rb")
          File.write(file, "class\n")
          wait.call { runner.state == :failed }
          assert_nil runner.pid
          5.times { |i| File.write(file, "# valid #{i}\n"); sleep 0.005 }
          wait.call { runner.state == :running }
        rescue Exception => error
          failure = error
        ensure
          runner.stop!
        end
      end
      runner.run
      editor.join
      raise failure if failure
      assert_equal 2, builds
      assert_nil runner.pid
    end
  end

  def test_snapshot_tracks_content_not_mtime_and_ignores_generated_outputs
    Dir.mktmpdir do |parent|
      capture_io { Dir.chdir(parent) { Hamster::Generator.create("WatchApp") } }
      root = File.join(parent, "watch_app")
      runner = Hamster::Dev::Runner.new(root)
      original = runner.snapshot
      File.write(File.join(root, "config/manifest.rb"), "generated\n")
      assert_equal original, runner.snapshot
      File.write(File.join(root, "app/routes/home/index/view.html.erb"), "changed\n")
      refute_equal original, runner.snapshot
    end
  end
end
