require "hamster/test_database"
require "tmpdir"
name = nil
Dir.mktmpdir do |migrations|
  File.write(File.join(migrations, "001_probe.sql"), "CREATE TABLE isolation_probe(id integer);")
  begin
    Hamster::Testing::TestDatabase.with_database(migrations_path: migrations) do |database|
      name = database.configuration.database
      Hamster::Testing::TestDatabase.rollback(database) { |connection| connection.execute("INSERT INTO isolation_probe VALUES (1)") }
      database.with_connection do |connection|
        raise "fixture leaked" unless connection.execute("SELECT count(*) AS count FROM isolation_probe").hashes.first["count"] == "0"
      end
      raise "exercise cleanup"
    end
  rescue RuntimeError => error
    raise unless error.message == "exercise cleanup"
  end
end
require "hamster/database/postgres"
config = Hamster::Database::Configuration.new(adapter: "postgres", host: ENV.fetch("TEST_DATABASE_HOST", "127.0.0.1"), port: ENV.fetch("TEST_DATABASE_PORT"), database: "postgres", username: ENV.fetch("TEST_DATABASE_USERNAME"), password: ENV.fetch("TEST_DATABASE_PASSWORD"), pool_size: 1, checkout_timeout: 5)
connection = Hamster::Database::Connection.new(Hamster::Database::Postgres.connect(config))
begin
  raise "database leaked" unless connection.execute("SELECT 1 FROM pg_database WHERE datname=$1", [name]).rows.empty?
ensure
  connection.close
end
puts "TEST_DATABASE_ISOLATION_OK"
