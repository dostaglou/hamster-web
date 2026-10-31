# frozen_string_literal: true
require "tmpdir"
require "open3"
require "timeout"
require "net/http"
require "rbconfig"

module Hamster
  module NativeSmoke
    module_function
    def run(root)
      entry = File.join(root, "test/native_server.rb")
      raise "Missing test/native_server.rb; add an explicit native test server" unless File.file?(entry)
      spinner = Gem::Specification.find_by_name("spinel-spinner").full_gem_path
      Dir.mktmpdir("hamster-native") do |temporary|
        binary = File.join(temporary, "server")
        flags = ["--require-gate", "-I", File.expand_path("..", __dir__), "-I", File.join(spinner, "lib"), "-I", root]
        output, status = Open3.capture2e(ENV.fetch("SPINEL", "spinel"), entry, *flags, "-o", binary, chdir: root)
        raise "Native compilation failed:\n#{output}" unless status.success?
        log = File.join(temporary, "server.log")
        pid = Process.spawn({"HOST" => "127.0.0.1", "PORT" => "0", "HAMSTER_ENV" => "test"}, binary, chdir: root, out: log, err: log)
        begin
          port = nil
          Timeout.timeout(15) do
            until port
              contents = File.read(log)
              port = contents[/SPINNER_READY \d+ (\d+)/, 1]&.to_i
              raise "Native server exited:\n#{contents}" if Process.waitpid(pid, Process::WNOHANG)
              sleep 0.05 unless port
            end
          end
          response = Net::HTTP.start("127.0.0.1", port, nil, nil, nil, nil, open_timeout: 3, read_timeout: 3) { |http| http.get("/up") }
          raise "Native /up returned #{response.code}" unless response.code == "200"
          if File.file?(File.join(root, "test/native_http.rb"))
            output, status = Open3.capture2e({"HAMSTER_TEST_URL" => "http://127.0.0.1:#{port}"}, RbConfig.ruby, "-I", File.expand_path("..", __dir__), "test/native_http.rb", chdir: root)
            raise "Native HTTP assertions failed:\n#{output}" unless status.success?
          end
        ensure
          begin
            Process.kill("TERM", pid)
            Timeout.timeout(12) { Process.waitpid(pid) }
          rescue Errno::ESRCH, Errno::ECHILD
            nil
          rescue Timeout::Error
            Process.kill("KILL", pid) rescue nil
            Process.waitpid(pid) rescue nil
          end
        end
      end
      true
    end
  end
end
