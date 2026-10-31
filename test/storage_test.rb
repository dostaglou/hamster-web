require "minitest/autorun"
require "tmpdir"
require "stringio"
require_relative "../lib/hamster/storage"
class StorageTest < Minitest::Test
  def test_disk_binary_roundtrip_exclusive_keys_limits_and_private_files
    Dir.mktmpdir do |root|
      disk = Hamster::Storage::Disk.new(root)
      key = "a" * 64
      bytes = (0..255).to_a.pack("C*") * 1000
      info = disk.put(StringIO.new(bytes), key: key)
      assert_equal bytes.bytesize, info["byte_size"]
      assert_equal Digest::SHA256.hexdigest(bytes), info["checksum"]
      io = disk.open(key)
      assert_equal bytes, io.read
      io.close
      assert_equal 0600, File.stat(File.join(root, key)).mode & 0777
      assert_raises(Errno::EEXIST) { disk.put(StringIO.new("other"), key: key) }
      assert_raises(Hamster::Storage::Error) { disk.put(StringIO.new("too large"), key: "b" * 64, max_bytes: 2) }
      refute disk.exists?("b" * 64)
      assert_empty Dir.glob(File.join(root, ".pending-*"))
      assert_raises(ArgumentError) { disk.open("../escape") }
      assert disk.delete(key)
      refute disk.delete(key)
      assert_raises(Hamster::Storage::MissingBlob) { disk.open(key) }
    end
  end
  def test_new_storage_directories_are_private
    Dir.mktmpdir do |parent|
      root = File.join(parent, "blobs")
      disk = Hamster::Storage::Disk.new(root)
      assert_equal 0700, File.stat(root).mode & 0777
      disk.put(StringIO.new(""), key: "f" * 64)
      assert_equal 0600, File.stat(File.join(root, "f" * 64)).mode & 0777
    end
  end

  def test_symlinks_are_rejected
    Dir.mktmpdir do |root|
      disk = Hamster::Storage::Disk.new(root)
      File.symlink(__FILE__, File.join(root, "c" * 64))
      assert_raises(Hamster::Storage::Error) { disk.open("c" * 64) }
      assert_raises(Hamster::Storage::Error) { disk.delete("c" * 64) }
    end
  end
end
