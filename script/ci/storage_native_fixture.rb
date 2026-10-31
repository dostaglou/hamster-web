require "hamster/storage"
require "stringio"
root = ARGV.fetch(0)
disk = Hamster::Storage::Disk.new(root)
key = "d" * 64
bytes = "\x00\x01\xff".b * 50000
metadata = disk.put(StringIO.new(bytes), key: key)
raise "size" unless metadata["byte_size"] == bytes.bytesize
io = disk.open(key)
raise "binary mismatch" unless io.read == bytes
io.close
raise "delete" unless disk.delete(key)
puts "STORAGE_NATIVE_OK"
