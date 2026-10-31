# frozen_string_literal: true
module Hamster
  class RequestBodyError < StandardError
    attr_reader :status
    def initialize(status, message)
      @status = status
      super(message)
    end
  end

  class UploadedFile
    attr_reader :filename, :content_type, :size, :io
    def initialize(filename, content_type, directory)
      @filename, @content_type, @size = filename, content_type, 0
      @path = File.join(directory, "hamster-#{Process.pid}-#{rand(1_000_000_000)}.upload")
      @io = File.open(@path, File::RDWR | File::CREAT | File::EXCL, 0600)
      @io.binmode
      @closed = false
    end
    def append(bytes)
      @io.write(bytes)
      @size += bytes.bytesize
    end
    def finish
      @io.flush
      @io.rewind
    end
    def copy_to(destination)
      @io.rewind
      File.open(destination, File::WRONLY | File::CREAT | File::EXCL, 0600) do |target|
        while (chunk = @io.read(65536))
          target.write(chunk)
        end
      end
      @io.rewind
      destination
    end
    def close
      return if @closed
      @closed = true
      begin
        @io.close unless @io.closed?
      ensure
        File.unlink(@path) if File.exist?(@path)
      end
    end
  end

  class FileBody
    def initialize(io, owned = true)
      @io, @owned, @closed = io, owned, false
    end
    def each
      while (chunk = @io.read(65536))
        yield chunk.b
      end
    end
    def close
      return if @closed
      @closed = true
      @io.close if @owned && !@io.closed?
    end
  end

  class RequestBody
    def initialize(body, context)
      @body, @context, @closed = body, context, false
    end
    def each
      @body.each { |chunk| yield chunk }
    end
    def close
      return if @closed
      @closed = true
      begin
        @body.close if @body.respond_to?(:close)
      ensure
        @context.close_uploads
      end
    end
  end

  module Downloads
    module_function
    def headers(filename, content_type, disposition)
      raise ArgumentError, "invalid disposition" unless %w[attachment inline].include?(disposition)
      raise ArgumentError, "invalid content type" unless content_type.match?(%r{\A[a-zA-Z0-9!\#$&^_.+-]+/[a-zA-Z0-9!\#$&^_.+-]+\z})
      name = filename.to_s
      raise ArgumentError, "invalid filename" if name.empty? || name.match?(/[\x00-\x1f\x7f\\\/]/) || !name.valid_encoding?
      ascii = name.gsub(/[^a-zA-Z0-9._-]/, "_")
      encoded = name.bytes.map { |b| ((b >= 65 && b <= 90) || (b >= 97 && b <= 122) || (b >= 48 && b <= 57) || [45,46,95].include?(b)) ? b.chr : "%#{b.to_s(16).upcase.rjust(2, '0')}" }.join
      {"content-type" => content_type, "content-disposition" => "#{disposition}; filename=\"#{ascii}\"; filename*=UTF-8''#{encoded}", "x-content-type-options" => "nosniff", "cache-control" => "no-store"}
    end

    def file(path, root:, filename: nil, content_type: "application/octet-stream", disposition: "attachment")
      root_path = File.realpath(root)
      absolute = File.expand_path(path, root_path)
      raise ArgumentError, "file outside download root" unless absolute.start_with?(root_path + File::SEPARATOR)
      cursor = File::SEPARATOR
      absolute.split(File::SEPARATOR).reject(&:empty?).each do |part|
        cursor = File.join(cursor, part)
        raise ArgumentError, "symlink download path" if File.symlink?(cursor)
      end
      before = File.stat(absolute)
      raise ArgumentError, "download must be a regular file" unless before.file?
      result_headers = headers(filename || File.basename(absolute), content_type, disposition)
      io = File.open(absolute, "rb")
      begin
        after = io.stat
        raise ArgumentError, "download path changed" unless after.file? && before.ino == after.ino && before.dev == after.dev && File.realpath(absolute) == absolute
        [200, result_headers, FileBody.new(io)]
      rescue StandardError
        io.close
        raise
      end
    end
  end
end
