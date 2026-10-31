require "minitest/autorun"
require_relative "../lib/hamster/cli"
require_relative "../lib/hamster/generators/runner"

class ComponentGeneratorsTest < Minitest::Test
  def app
    Dir.mktmpdir do |parent|
      capture_io { Dir.chdir(parent) { Hamster::Generator.create("PartsApp") } }
      yield File.join(parent, "parts_app")
    end
  end
  def snapshot(root)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: root).select { |p| File.file?(File.join(root, p)) }.to_h { |p| [p, File.binread(File.join(root, p))] }
  end
  def generate(root, *args)
    result = nil
    capture_io { result = Hamster::Generators::Runner.run(root, args) }
    result
  end
  def test_standalone_parts_compose_and_json_lists_exact_changes
    app do |root|
      generate(root, "action", "posts/show", "--no-view")
      generate(root, "view", "posts/show")
      generate(root, "route", "posts/show", "--path", "/posts/:id", "--name", "post")
      generate(root, "table", "posts", "title:text", "published:boolean")
      generate(root, "migration", "create_posts", "--timestamp", "20261101000000")
      assert_empty Hamster::Build::Manifest.check(root)
      before = snapshot(root)
      report = generate(root, "endpoint", "posts/edit", "--view", "--json")
      after = snapshot(root)
      changed = after.keys.select { |key| before[key] != after[key] }.sort
      assert_equal changed, report["files"]
      assert File.file?(File.join(root, "db/migrations/20261101000000_create_posts.rb"))
      assert_includes File.read(File.join(root, "db/tables/posts.rb")), "write: :both"
      assert_empty Hamster::Build::Manifest.check(root)
    end
  end
  def test_dry_runs_and_failures_leave_all_files_unchanged
    app do |root|
      before = snapshot(root)
      report = generate(root, "endpoint", "posts/show", "--view", "--dry-run", "--json")
      assert report["dry_run"]
      assert_includes report["files"], "app/routes/posts/show/action.rb"
      assert_equal before, snapshot(root)
      assert_raises(ArgumentError) { generate(root, "endpoint", "posts/show", "--before", "missing") }
      assert_equal before, snapshot(root)
      generate(root, "endpoint", "posts/show", "--path", "/posts/:id")
      before = snapshot(root)
      assert_raises(ArgumentError) { generate(root, "endpoint", "posts/other", "--path", "/posts/:slug") }
      assert_raises(ArgumentError) { generate(root, "table", "posts", "id:bigint") }
      assert_equal before, snapshot(root)
      File.symlink(Dir.tmpdir, File.join(root, "app/routes/escape"))
      assert_raises(ArgumentError) { generate(root, "view", "escape/show") }
      assert_equal before, snapshot(root).reject { |path, _| path.start_with?("app/routes/escape/") }
    end
  end
end
