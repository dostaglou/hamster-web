require "minitest/autorun"
require_relative "../lib/hamster/data"

class SchemaContractTest < Minitest::Test
  class Enabled < Hamster::Table
    table :contract_entries
    column :id, type: :bigint, nullable: false
    column :title, type: :text, write: :both
    column :secret, type: :text, enabled: false, write: :both
    column :updated_at, type: :timestamptz, enabled: false
  end
  class Disabled < Enabled
    table :disabled_entries, enabled: false
  end
  class Inherited < Disabled; end

  class Catalog
    attr_reader :calls
    def initialize(present)
      @present, @calls = present, []
    end
    def execute(sql, binds)
      @calls << [sql, binds]
      # A relation without visible columns still produces one LEFT JOIN row.
      rows = @present ? [[nil, nil, nil]] : []
      Hamster::Database::Result.new(columns: %w[name type_id not_null], rows: rows, types: [], command_tag: "SELECT")
    end
  end

  def test_flags_inherit_independently_and_require_booleans
    assert Enabled.enabled?
    refute Disabled.enabled?
    refute Inherited.enabled?
    refute Enabled.columns[:secret][:enabled]
    assert Disabled.columns[:title][:enabled]
    assert_raises(Hamster::Read::ValidationError) { Class.new(Hamster::Table).table(:invalid, enabled: nil) }
  end

  def test_all_enabled_and_present_combinations
    [Enabled, Disabled].each do |table|
      [true, false].each do |present|
        connection = Catalog.new(present)
        report = Hamster::Read::Schema.report(connection, [table])
        declaration = report.fetch("tables").first
        assert_equal present, declaration["exists"]
        assert_equal table.enabled?, declaration["enabled"]
        assert connection.calls.all? { |sql, _| sql.lstrip.start_with?("SELECT") }
        if !table.enabled?
          assert report["valid"]
          assert declaration["columns"].none? { |column| column["checked"] }
        elsif present
          refute report["errors"].any? { |error| error.include?("table is missing") }
          assert report["errors"].any? { |error| error.include?("title: column is missing") }
          refute report["errors"].any? { |error| error.include?("secret") || error.include?("updated_at") }
        else
          assert_equal ["public.contract_entries: table is missing"], report["errors"]
        end
      end
    end
  end

  def test_disabled_sources_fail_even_for_constant_projections_and_joins
    connection = Catalog.new(false)
    [Disabled.all, Disabled.select(Hamster::SQL.count),
     Enabled.joins(Disabled, on: Enabled[:id].eq(Disabled[:id])),
     Enabled.left_joins(Disabled.as(:other), on: Hamster::SQL.bind(1).eq(1))].each do |relation|
      assert_raises(Hamster::Read::DisabledTableError) { relation.load(connection: connection) }
    end
    assert_empty connection.calls
    assert_raises(Hamster::Read::DisabledColumnError) { Enabled.select(:secret).compile }
    assert_raises(Hamster::Read::DisabledColumnError) { Enabled.where(secret: "x").compile }
    assert_raises(Hamster::Read::DisabledColumnError) { Enabled.order(:secret).compile }
    refute_includes Enabled.all.to_sql, '"secret"'
  end

  def test_disabled_automatic_timestamps_are_not_written
    connection = Object.new
    def connection.execute(sql, binds)
      raise "disabled timestamp used" if sql.include?("updated_at")
      Hamster::Database::Result.new(columns: ["id"], rows: [["1"]], types: [20], command_tag: "INSERT")
    end
    result = Hamster::Record.with_connection(connection) { Enabled.create(title: "Hello") }
    assert result.success?
    assert_equal 1, result.record.id.to_i
  end

  def test_disabled_record_access_and_persistence_never_issue_sql
    record = Disabled.new(id: 1, title: "x")
    connection = Catalog.new(false)
    Hamster::Record.with_connection(connection) do
      [-> { record.id }, -> { record.title = "x" }, -> { Disabled.create(title: "x") },
       -> { record.update(title: "x") }, -> { record.destroy }].each do |operation|
        assert_raises(Hamster::Read::DisabledTableError, &operation)
      end
      enabled = Enabled.new(id: 1, secret: "x")
      assert_raises(Hamster::Read::DisabledColumnError) { enabled.secret }
      assert_raises(Hamster::Read::DisabledColumnError) { enabled.secret = "y" }
      assert_raises(Hamster::Read::DisabledColumnError) { Enabled.create(secret: "x") }
      assert_raises(Hamster::Read::DisabledColumnError) { enabled.update(secret: "x") }
    end
    assert_empty connection.calls
    assert_equal ["title"], Enabled.create_fields
    assert_equal ["title"], Enabled.update_fields
  end
end
