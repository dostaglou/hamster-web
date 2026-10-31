# frozen_string_literal: true
module Hamster
  class Multipart
    attr_reader :fields, :uploads
    def initialize(input, content_type, options = {})
      match = content_type.match(/\Amultipart\/form-data\s*;\s*boundary=(?:"([^"\r\n]+)"|([^;\s]+))\s*\z/i)
      boundary = match && (match[1] || match[2])
      fail_body(400, "invalid multipart boundary") unless boundary && boundary.bytesize <= 70 && boundary.match?(/\A[ -~]+\z/)
      @input, @buffer, @total = input, "".b, 0
      @maximum = options.fetch(:max_body_bytes, 1048576)
      @parts = options.fetch(:max_parts, 128)
      @header_limit = options.fetch(:max_part_header_bytes, 16384)
      @field_limit = options.fetch(:max_field_bytes, 65536)
      @file_limit = options.fetch(:max_file_bytes, @maximum)
      @directory = options.fetch(:upload_directory, ENV.fetch("TMPDIR", "/tmp"))
      [@maximum, @parts, @header_limit, @field_limit, @file_limit].each do |limit|
        raise ArgumentError, "multipart limits must be positive integers" unless limit.is_a?(Integer) && limit > 0
      end
      @fields, @uploads, @all = {}, {}, []
      @boundary = boundary.b
    end
    def fail_body(status, message)
      raise RequestBodyError.new(status, message)
    end
    def read_more
      chunk = @input.read(16384)
      fail_body(400, "truncated multipart body") if chunk.nil? || chunk.empty?
      @total += chunk.bytesize
      fail_body(413, "multipart body too large") if @total > @maximum
      @buffer << chunk.b
    end
    def take_until(marker, limit)
      loop do
        position = @buffer.index(marker)
        if position
          fail_body(413, "multipart section too large") if position > limit
          value = @buffer.byteslice(0, position)
          @buffer = @buffer.byteslice(position + marker.bytesize, @buffer.bytesize) || "".b
          return value
        end
        fail_body(413, "multipart section too large") if @buffer.bytesize > limit + marker.bytesize
        read_more
      end
    end
    def parse
      read_more while @buffer.bytesize < @boundary.bytesize + 4
      prefix = "--#{@boundary}\r\n".b
      fail_body(400, "invalid multipart opening") unless @buffer.start_with?(prefix)
      @buffer = @buffer.byteslice(prefix.bytesize, @buffer.bytesize) || "".b
      count = 0
      loop do
        count += 1
        fail_body(413, "too many multipart parts") if count > @parts
        raw = take_until("\r\n\r\n".b, @header_limit)
        headers = {}
        raw.split("\r\n").each do |line|
          key, value = line.split(":", 2)
          fail_body(400, "invalid multipart header") unless value && key.match?(/\A[a-zA-Z0-9-]+\z/) && !headers.key?(key.downcase)
          headers[key.downcase] = value.strip
        end
        disposition = headers.fetch("content-disposition", "")
        match = disposition.match(/\Aform-data;\s*name="([^"\r\n\x00]+)"(?:;\s*filename="([^"\r\n\x00]*)")?\z/)
        fail_body(400, "invalid multipart disposition") unless match
        name, filename = match[1], match[2]
        upload = nil
        value = "".b
        unless filename.nil?
          filename = filename.dup.force_encoding("UTF-8")
          fail_body(400, "unsafe upload filename") if filename.match?(/[\\\/\x00-\x1f\x7f]/) || !filename.valid_encoding? || [".", ".."].include?(filename)
          content_type = headers.fetch("content-type", "application/octet-stream")
          fail_body(400, "invalid upload content type") unless content_type.match?(%r{\A[a-zA-Z0-9!\#$&^_.+-]+/[a-zA-Z0-9!\#$&^_.+-]+\z})
          upload = UploadedFile.new(filename, content_type, @directory)
          @all << upload
        end
        marker = "\r\n--#{@boundary}".b
        loop do
          position = @buffer.index(marker)
          if position
            read_more while @buffer.bytesize < position + marker.bytesize + 2
            suffix = @buffer.byteslice(position + marker.bytesize, 2)
            if suffix == "--" || suffix == "\r\n"
              emit(@buffer.byteslice(0, position), upload, value)
              @buffer = @buffer.byteslice(position + marker.bytesize, @buffer.bytesize) || "".b
              break
            end
            # A boundary-like sequence within binary data is ordinary content.
            emit(@buffer.byteslice(0, position + 2), upload, value)
            @buffer = @buffer.byteslice(position + 2, @buffer.bytesize) || "".b
          elsif @buffer.bytesize > marker.bytesize + 2
            length = @buffer.bytesize - marker.bytesize - 2
            emit(@buffer.byteslice(0, length), upload, value)
            @buffer = @buffer.byteslice(length, @buffer.bytesize) || "".b
          else
            read_more
          end
        end
        if upload
          upload.finish
          (@uploads[name] ||= []) << upload
        else
          value.force_encoding("UTF-8")
          fail_body(400, "invalid multipart text encoding") unless value.valid_encoding?
          (@fields[name] ||= []) << value
        end
        ending = @buffer.byteslice(0, 2)
        @buffer = @buffer.byteslice(2, @buffer.bytesize) || "".b
        if ending == "--"
          while (tail = @input.read(16384)) && !tail.empty?
            @total += tail.bytesize
            fail_body(413, "multipart body too large") if @total > @maximum
            @buffer << tail.b
            fail_body(400, "invalid multipart ending") if @buffer.bytesize > 2
          end
          fail_body(400, "invalid multipart ending") unless @buffer.empty? || @buffer == "\r\n"
          break
        end
      end
      self
    rescue StandardError
      close
      raise
    end
    def emit(bytes, upload, value)
      if upload
        fail_body(413, "uploaded file too large") if upload.size + bytes.bytesize > @file_limit
        upload.append(bytes)
      else
        fail_body(413, "multipart field too large") if value.bytesize + bytes.bytesize > @field_limit
        value << bytes
      end
    end
    def close
      @all.each(&:close)
    end
  end
end
