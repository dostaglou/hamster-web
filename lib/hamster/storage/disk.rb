# frozen_string_literal: true
require "digest"
require "securerandom"
module Hamster
  module Storage
    class Error < StandardError; end
    class MissingBlob < Error; end
    class IntegrityError < Error; end
    class Unauthorized < Error; end
    class InUse < Error; end

    class Disk
      def initialize(root)
        @root = File.expand_path(root)
        raise ArgumentError, "storage root cannot be a symlink" if File.symlink?(@root)
        Dir.mkdir(@root, 0700) unless File.exist?(@root)
        raise Error, "storage directory must be private (0700)" unless (File.stat(@root).mode & 0077) == 0
        @canonical = File.realpath(@root)
        @identity = File.stat(@root).ino
      end
      def path(key)
        raise ArgumentError, "invalid blob key" unless key.is_a?(String) && key.match?(/\A[0-9a-f]{64}\z/)
        raise Error, "storage root changed" if File.symlink?(@root) || File.realpath(@root) != @canonical || File.stat(@root).ino != @identity
        File.join(@canonical, key)
      end
      def put(io, key:, max_bytes: 1048576)
        target = path(key)
        raise ArgumentError, "storage limit must be positive" unless max_bytes.is_a?(Integer) && max_bytes > 0
        digest, size, created, complete = Digest::SHA256.new, 0, false, false
        begin
          File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0600) do |file|
            created = true
            file.binmode
            while (chunk = io.read(65536))
              break if chunk.empty?
              size += chunk.bytesize
              raise Error, "blob exceeds storage limit" if size > max_bytes
              digest.update(chunk)
              file.write(chunk)
            end
            file.flush
            file.fsync
          end
          complete = true
          {"byte_size" => size, "checksum" => digest.hexdigest}
        ensure
          File.unlink(target) if created && !complete && File.exist?(target)
        end
      end
      def open(key)
        filename = path(key)
        before = File.lstat(filename)
        raise Error, "blob is not a regular file" unless before.file? && !before.symlink?
        io = File.open(filename, "rb")
        after = io.stat
        unless after.file? && after.ino == before.ino && after.dev == before.dev
          io.close
          raise Error, "blob changed while opening"
        end
        io
      rescue Errno::ENOENT
        raise MissingBlob, "Blob file is missing"
      end
      def exists?(key)
        filename = path(key)
        File.file?(filename) && !File.symlink?(filename)
      end
      def delete(key)
        filename = path(key)
        raise Error, "refusing symlink blob" if File.symlink?(filename)
        File.unlink(filename)
        true
      rescue Errno::ENOENT
        false
      end
      def cleanup_temporary(older_than:)
        Dir.glob(File.join(@canonical, ".pending-*")).count do |file|
          next false if File.symlink?(file) || !File.file?(file) || File.mtime(file) >= older_than
          File.unlink(file)
          true
        end
      end
    end
  end
end
