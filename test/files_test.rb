require "minitest/autorun"
require "tmpdir"
require "stringio"
require_relative "../lib/hamster/web"

class FilesTest < Minitest::Test
  def body(filename = 'binary.bin', payload = "\x00\xff\r\n--edgeX\x00".b)
    "--edge\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\none\r\n--edge\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\ntwo\r\n--edge\r\nContent-Disposition: form-data; name=\"file\"; filename=\"#{filename}\"\r\nContent-Type: application/octet-stream\r\n\r\n".b + payload + "\r\n--edge--\r\n".b
  end
  def parse(bytes, options = {})
    Hamster::Multipart.new(StringIO.new(bytes), 'multipart/form-data; boundary="edge"', options).parse
  end
  def test_binary_repeated_fields_and_cleanup
    Dir.mktmpdir do |dir|
      parser = parse(body, upload_directory: dir)
      assert_equal %w[one two], parser.fields['title']
      upload = parser.uploads['file'].first
      assert_equal "\x00\xff\r\n--edgeX\x00".b, upload.io.read
      assert_equal 12, upload.size
      upload.copy_to("#{dir}/durable")
      assert_equal 2, Dir.children(dir).size
      parser.close
      parser.close
      assert_equal ['durable'], Dir.children(dir)
      assert_equal upload.size, File.size("#{dir}/durable")
    end
  end
  def test_empty_limits_malformed_and_filenames
    parser = parse(body('empty', ''.b))
    assert_equal 0, parser.uploads['file'].first.size
    parser.close
    ['../escape', 'back\\slash', '..'].each do |filename|
      assert_raises(Hamster::RequestBodyError) { parse(body(filename)) }
    end
    [ {max_parts: 1}, {max_body_bytes: 10}, {max_field_bytes: 2}, {max_file_bytes: 1}, {max_part_header_bytes: 5} ].each do |limits|
      error = assert_raises(Hamster::RequestBodyError) { parse(body, limits) }
      assert_equal 413, error.status
    end
    assert_raises(Hamster::RequestBodyError) { parse(body.byteslice(0, 100)) }
  end
  def test_small_reads_and_parser_failure_cleanup
    input_class = Class.new do
      def initialize(bytes); @io = StringIO.new(bytes); end
      def read(length); @io.read([length, 3].min); end
    end
    Dir.mktmpdir do |dir|
      parser = Hamster::Multipart.new(input_class.new(body), 'multipart/form-data; boundary=edge', upload_directory: dir).parse
      assert_equal 12, parser.uploads["file"].first.io.read.bytesize
      parser.close
      assert_empty Dir.children(dir)
      assert_raises(Hamster::RequestBodyError) { parse(body.byteslice(0, body.bytesize - 10), upload_directory: dir) }
      assert_empty Dir.children(dir)
    end
  end

  def test_download_root_symlinks_headers_and_streaming
    Dir.mktmpdir do |root|
      File.binwrite("#{root}/data", "\x00\xff".b * 100000)
      response = Hamster::Downloads.file('data', root: root, filename: '日本語.bin')
      assert_includes response[1]['content-disposition'], "filename*=UTF-8''"
      chunks = []
      response[2].each { |c| chunks << c }
      assert_operator chunks.size, :>, 1
      assert_equal 200000, chunks.sum(&:bytesize)
      response[2].close
      assert_raises(ArgumentError) { Hamster::Downloads.file('../outside', root: root) }
      File.symlink("#{root}/data", "#{root}/link")
      assert_raises(ArgumentError) { Hamster::Downloads.file('link', root: root) }
      assert_raises(ArgumentError) { Hamster::Downloads.headers("x\r\ny", 'text/plain', 'attachment') }
      assert_raises(ArgumentError) { Hamster::Downloads.headers('x', "text/plain\r\nx:y", 'attachment') }
    end
  end
end
