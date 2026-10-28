require "minitest/autorun"
require "open3"
require "rbconfig"
require_relative "../lib/hamster/console"
require_relative "../lib/hamster/schema_validation"

class ConsoleAndSchemaTest < Minitest::Test
  class Entry < Hamster::Table
    table "entries"
    column :id, type: :bigint, nullable: false
    column :label, type: :text
  end

  class Database
    attr_reader :closed, :statements
    attr_accessor :catalog, :failure
    def initialize
      @catalog = [["id", "20", "true"], ["label", "25", "false"]]
      @statements = []
    end
    def with_connection
      Hamster::Record.with_connection(self) { yield self }
    end
    def execute(sql, params)
      @statements << [sql, params]
      raise "connection failed" if failure
      Hamster::Database::Result.new(columns: %w[name type_id not_null], rows: catalog, types: [], command_tag: "SELECT")
    end
    def shutdown
      @closed = true
    end
  end

  class Application
    attr_reader :database, :closed
    def initialize(database)
      @database = database
    end
    def shutdown
      @closed = true
      database.shutdown if database
    end
  end

  def test_console_exposes_app_and_scoped_connection_and_cleans_up
    database = Database.new
    app = Application.new(database)
    capture_io do
      Hamster::Console.run(app) do |workspace|
        assert_same app, workspace.local_variable_get(:app)
        assert_same app, workspace.local_variable_get(:application)
        assert_same database, workspace.local_variable_get(:database)
        assert_same database, Hamster::Record.connection
      end
    end
    assert app.closed
    assert database.closed
    assert_raises(Hamster::Record::MissingConnection) { Hamster::Record.connection }
  end

  def test_console_failure_cleans_up
    app = Application.new(Database.new)
    capture_io do
      assert_raises(RuntimeError) { Hamster::Console.run(app) { raise "session failed" } }
    end
    assert app.closed
    assert_raises(Hamster::Record::MissingConnection) { Hamster::Record.connection }
  end

  def test_interactive_console_can_evaluate_and_exit
    source = <<~RUBY
      require "hamster/console"
      class ConsoleApp
        def database; nil; end
        def shutdown; puts "CONSOLE_CLEANUP"; end
      end
      Hamster::Console.run(ConsoleApp.new)
    RUBY
    output, status = Open3.capture2e({"IRBRC" => File::NULL}, RbConfig.ruby,
      "-I", File.expand_path("../lib", __dir__), "-e", source,
      stdin_data: "puts app.class.name\nexit\n")
    assert status.success?, output
    assert_includes output, "ConsoleApp"
    assert_includes output, "CONSOLE_CLEANUP"
  end

  def test_schema_validation_is_read_only_and_reports_mismatches
    database = Database.new
    assert_empty Hamster::SchemaValidation.run(database, [Entry])
    assert database.closed
    assert database.statements.all? { |sql, _| sql.lstrip.start_with?("SELECT") }
    assert_equal ["public", "entries"], database.statements.first[1]

    database = Database.new
    database.catalog = [["id", "25", "false"]]
    issues = Hamster::SchemaValidation.run(database, [Entry])
    assert issues.any? { |issue| issue.include?("incompatible type") }
    assert issues.any? { |issue| issue.include?("permits NULL") }
    assert issues.any? { |issue| issue.include?("label: column is missing") }
    assert database.closed
  end

  def test_schema_connection_failure_cleans_up
    database = Database.new
    database.failure = true
    assert_raises(RuntimeError) { Hamster::SchemaValidation.run(database, [Entry]) }
    assert database.closed
  end
end
