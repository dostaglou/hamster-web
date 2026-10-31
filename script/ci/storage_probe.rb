require "hamster/storage"
require "hamster/test_database"
require "tmpdir"
require "stringio"
class FlakyDisk < Hamster::Storage::Disk
  attr_accessor :fail_delete
  def delete(key)
    if fail_delete
      self.fail_delete = false
      raise Hamster::Storage::Error, "simulated disk failure"
    end
    super
  end
end
Dir.mktmpdir do |root|
  migrations = File.join(root, "migrations")
  Dir.mkdir(migrations)
  File.write(File.join(migrations, "001_storage.sql"), Hamster::Storage::Attachments.migration_sql)
  Hamster::Testing::TestDatabase.with_database(migrations_path: migrations) do |database|
    directory = File.join(root, "blobs")
    disk = FlakyDisk.new(directory)
    service = Hamster::Storage::Attachments.new(database: database, adapter: disk)
    authorize = ->(metadata) { metadata["owner"] == "user-1" }
    bytes = (0..255).to_a.pack("C*") * 1024
    blob = service.upload(StringIO.new(bytes), filename: "../display.bin", owner: "user-1")
    one = service.attach(blob_id: blob, record_type: "Post", record_id: "1", name: "file", owner: "user-1", authorize: authorize)
    two = service.attach(blob_id: blob, record_type: "Post", record_id: "2", name: "file", owner: "user-1", authorize: authorize)
    begin
      service.open(blob, authorize: ->(_metadata) { false })
      raise "authorization bypass"
    rescue Hamster::Storage::Unauthorized
    end
    io = service.open(blob, authorize: authorize)
    raise "binary mismatch" unless io.read == bytes
    io.close
    begin
      service.delete(blob, authorize: authorize)
      raise "shared reference deleted"
    rescue Hamster::Storage::InUse
    end
    service.detach(one, authorize: authorize)
    begin
      service.delete(blob, authorize: authorize)
      raise "remaining reference deleted"
    rescue Hamster::Storage::InUse
    end
    metadata = service.metadata(blob)
    key = metadata.fetch("storage_key")
    File.binwrite(File.join(directory, key), "corrupted")
    begin
      service.open(blob, authorize: authorize)
      raise "corruption accepted"
    rescue Hamster::Storage::IntegrityError
    end
    service.detach(two, authorize: authorize)
    service.delete(blob, authorize: authorize)
    raise "deletion not idempotent" if service.delete(blob, authorize: authorize)
    recovery = service.upload(StringIO.new("recover"), filename: "recover.bin", owner: "user-1")
    disk.fail_delete = true
    begin
      service.delete(recovery, authorize: authorize)
      raise "disk failure was ignored"
    rescue Hamster::Storage::Error
    end
    database.with_connection do |connection|
      raise "deleting state lost" unless connection.execute("SELECT state FROM hamster_blobs WHERE id=$1", [recovery]).hashes.first["state"] == "deleting"
    end
    service.cleanup(older_than: Time.now + 1)
    missing = service.upload(StringIO.new("missing"), filename: "missing.bin", owner: "user-1")
    disk.delete(service.metadata(missing).fetch("storage_key"))
    begin
      service.open(missing, authorize: authorize)
      raise "missing file accepted"
    rescue Hamster::Storage::MissingBlob
    end
    orphan = service.upload(StringIO.new("orphan"), filename: "orphan.bin", owner: "user-1")
    service.cleanup(older_than: Time.now + 1)
    raise "orphan metadata" if service.metadata(orphan)
    begin
      service.upload(StringIO.new("too big"), filename: "failed.bin", owner: "user-1", max_bytes: 1)
    rescue Hamster::Storage::Error
    end
    service.cleanup(older_than: Time.now + 1)
    database.with_connection do |connection|
      raise "pending leak" unless connection.execute("SELECT id FROM hamster_blobs").rows.empty?
    end
  end
end
puts "ATTACHMENTS_DATABASE_OK"
