require "minitest/autorun"
require "tmpdir"
require_relative "../lib/hamster/data"
require_relative "../lib/hamster/database/migrator"
require_relative "../lib/hamster/build/manifest"

class MigratorTest < Minitest::Test
  def test_migrations_are_not_compiled_into_application
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p("#{root}/db/migrations")
      File.write("#{root}/db/migrations/001_example.rb", "class Example < Hamster::Migration; end")
      refute_includes Hamster::Build::Manifest.outputs(root).fetch("config/manifest.rb"), "migrations"
    end
  end

  def test_quoted_identifiers_and_supported_types
    statements = []
    connection = Object.new
    connection.define_singleton_method(:execute_script) { |sql| statements << sql }
    migration = Hamster::Migration.new
    migration.connection = connection
    migration.create_table('odd"table', columns: {name: :text})
    assert_equal 'CREATE TABLE "odd""table" ("name" TEXT)', statements.first
    assert_raises(ArgumentError) { migration.add_column("users", "name", :injected) }
  end

  def test_postgres_lifecycle_and_concurrency
    skip "set HAMSTER_TEST_DATABASE=1 with explicit TEST_DATABASE settings" unless ENV["HAMSTER_TEST_DATABASE"] == "1"
    $LOAD_PATH.unshift(File.expand_path("../../release_check/vendor/packages/pg-0.2.0", __dir__))
    require_relative "../lib/hamster/test_database"
    Dir.mktmpdir do |root|
      Hamster::Testing::TestDatabase.with_database(migrations_path: root) do |db|
        config = db.configuration
      db.with_connection do |c|
        c.execute_script("DROP TABLE IF EXISTS hamster_migration_events, schema_migrations, migration_probe; CREATE TABLE schema_migrations(version TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL); INSERT INTO schema_migrations VALUES ('001', NOW())")
      end
      File.write("#{root}/001_legacy.sql", "SELECT 1")
      File.write("#{root}/002_probe.rb", <<~SOURCE)
        class Probe < Hamster::Migration
          def up
            execute("SELECT pg_sleep(0.2)")
            create_table :migration_probe, columns: {id: :integer}
          end
          def down
            drop_table :migration_probe
          end
        end
      SOURCE
      pids = 2.times.map do
        fork do
          child = Hamster::Database.new(config, migrations_path: root)
          begin
            child.migrate!
          ensure
            child.shutdown
          end
          exit! 0
        end
      end
      assert pids.map { |pid| Process.wait2(pid).last.success? }.all?
      assert_equal %w[legacy_unknown applied], db.migration_status.map { |f| f["status"] }
      assert_equal 1, db.migration_history["events"].size
      assert_equal JSON.generate(db.migration_history), JSON.generate(db.migration_history)
      assert_raises(Hamster::Database::ConfigurationError) { db.rollback!(2) }
      assert_equal "applied", db.migration_status.last["status"]
      db.rollback!
      assert_equal "pending", db.migration_status.last["status"]
      db.migrate!
      File.write("#{root}/003_failure.sql", "CREATE TABLE failed_migration_probe (id INTEGER); SELECT * FROM no_such_migration_table;")
      assert_raises(Hamster::Database::Error) { db.migrate! }
      db.with_connection do |c|
        assert_nil c.execute("SELECT to_regclass('failed_migration_probe') AS name").hashes.first["name"]
      end
      assert_equal "pending", db.migration_status.last["status"]
      File.unlink("#{root}/003_failure.sql")
      File.write("#{root}/002_probe.rb", "# changed")
      assert_raises(Hamster::Database::ConfigurationError) { db.migrate! }
      File.unlink("#{root}/002_probe.rb")
      assert_equal "missing", db.migration_status.last["status"]
      File.write("#{root}/001_duplicate.sql", "SELECT 1")
      assert_raises(Hamster::Database::ConfigurationError) { db.migration_status }
      end
    end
  end
end
