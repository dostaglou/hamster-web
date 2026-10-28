require "minitest/autorun"
require "tmpdir"
require_relative "../lib/hamster/data"

class DatabaseTest < Minitest::Test
  def configuration
    Hamster::Database::Configuration.from_env({"DATABASE_USERNAME" => "tester"}, app_name: "sample")
  end

  class Catalog
    attr_accessor :tracking, :applied
    def initialize
      @tracking = true
      @applied = []
    end
    def execute(sql, params = [])
      values = if sql.include?("to_regclass")
                 [[tracking ? "schema_migrations" : nil]]
               else
                 applied.map { |version| [version] }
               end
      column = sql.include?("to_regclass") ? "name" : "version"
      Hamster::Database::Result.new(columns: [column], rows: values, types: [], command_tag: "SELECT")
    end
  end

  class Probe < Hamster::Database
    attr_accessor :connection
    def with_connection
      yield connection
    end
  end

  def test_configuration_uses_application_identity_without_driver
    assert_equal "sample_development", configuration.database
    env = {"DATABASE_USERNAME" => "tester", "HAMSTER_ENV" => "test"}
    assert_equal "sample_test", Hamster::Database::Configuration.from_env(env, app_name: "sample").database
  end

  def test_migration_verification_uses_app_versions_without_blog_tables
    Dir.mktmpdir do |root|
      database = Probe.new(configuration, migrations_path: root)
      database.connection = Catalog.new
      assert database.verify!
      File.write(File.join(root, "001_create_widgets.sql"), "CREATE TABLE widgets (id integer);")
      error = assert_raises(Hamster::Database::ConfigurationError) { database.verify! }
      assert_includes error.message, "pending migrations 001"
      database.connection.applied = ["001"]
      assert database.verify!
      database.connection.tracking = false
      assert_raises(Hamster::Database::ConfigurationError) { database.verify! }
    end
  end
end
