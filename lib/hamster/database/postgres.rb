# frozen_string_literal: true
require "socket"
require "securerandom"
require "digest"
require_relative "../data"

if RUBY_ENGINE == "ruby"
  require "openssl"
  require "pg/client"
else
  require "pg"
end

module Hamster
  class Database
    class Postgres
      def self.connect(configuration)
        if RUBY_ENGINE == "ruby"
          transport = RubyTransport.new(configuration.host, configuration.port)
          connection = PgClientCore.new(transport, configuration.username, configuration.database,
                                        configuration.password, SecureRandom.urlsafe_base64(18))
          connection.connect!
          connection
        else
          PG.connect(configuration.host, configuration.port, configuration.database,
                     configuration.username, configuration.password)
        end
      rescue PG::Error => error
        raise ConnectionError.new("postgres connection failed", original: error,
                                  sqlstate: sqlstate(error))
      rescue StandardError => error
        raise ConnectionError.new("postgres connection failed: #{error.message}", original: error)
      end

      def self.sqlstate(error)
        error.result.error_field(PG::PG_DIAG_SQLSTATE)
      rescue StandardError
        nil
      end

      class RubyTransport
        def initialize(host, port)
          @socket = TCPSocket.new(host, port)
        end

        def write(data)
          offset = 0
          while offset < data.bytesize
            offset += @socket.write(data.byteslice(offset, data.bytesize - offset))
          end
          offset
        end

        def read_some(max)
          @socket.readpartial(max)
        rescue EOFError
          ""
        end

        def close
          @socket.close unless @socket.closed?
        end
      end
    end
  end
end
