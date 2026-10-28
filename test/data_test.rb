require "minitest/autorun"
require_relative "../lib/hamster/data"

class DataTest < Minitest::Test
  class Item < Hamster::Table
    table "items"
    column :id, type: :bigint, nullable: false
    column :title, type: :text, nullable: false, write: :both
    def self.validate_create(attributes)
      attributes[:title].to_s.empty? ? ["Title required"] : []
    end
  end
  class Child < Item
    column :note, type: :text
  end
  class Titles < Hamster::Query
    from Item
    field :label, source: Item[:title]
  end
  class Connection
    attr_reader :sql, :binds
    def execute(sql, binds)
      @sql, @binds = sql, binds
      Hamster::Database::Result.new(columns: ["id"], rows: [["3"]], types: [20], command_tag: "INSERT")
    end
  end

  def test_persistence_without_timestamp_columns_and_connection_restoration
    connection = Connection.new
    result = Hamster::Record.with_connection(connection) { Item.create(title: "a' OR 1=1") }
    assert result.success?
    assert_equal "a' OR 1=1", result.record.title
    assert_equal ["a' OR 1=1"], connection.binds
    refute_includes connection.sql, "a' OR"
    refute_includes connection.sql, "created_at"
    assert_raises(Hamster::Record::MissingConnection) { Hamster::Record.connection }
  end

  def test_invalid_attributes_and_write_permissions
    result = Item.create(title: "")
    refute result.success?
    assert_equal :invalid, result.code
    assert_raises(Hamster::Record::ValidationError) { result.value! }
    assert_raises(ArgumentError) { Item.create(id: 1, title: "x") }
    assert Child.columns.key?(:title)
    refute Item.columns.key?(:note)
  end

  def test_compilation_binds_and_typed_decoding
    relation = Item.where(title: "a' OR 1=1").order(:id).limit(2)
    compiled = relation.compile
    assert_equal ["a' OR 1=1", 2], compiled.binds
    refute_includes compiled.sql, "a' OR"
    result = Hamster::Database::Result.new(columns: %w[id title], rows: [["7", "Hello"]], types: [20, 25], command_tag: "SELECT")
    rows = Hamster::Read::Decoder.new(compiled).decode(result)
    assert_instance_of Item, rows.first
    assert_equal 7, rows.first.id
    assert_equal "Hello", rows.first.title
  end

  def test_named_projection_validation_and_decoding
    assert Hamster::Query.registry.include?(Titles)
    compiled = Titles.all.compile
    result = Hamster::Database::Result.new(columns: ["label"], rows: [["Hello"]], types: [25], command_tag: "SELECT")
    row = Hamster::Read::Decoder.new(compiled).decode(result).first
    assert_instance_of Titles, row
    assert_equal "Hello", row.label
  end
end
