# frozen_string_literal: true
require "spinner"

# Spinel 10f112c51 emits null-terminated writes for boxed socket arguments.
# Keep both the IO handle and binary string typed at the syscall. Spinel's
# IO.for_fd(autoclose: false) wraps a dup; closing it leaves Spinner's fd open.
# CRuby's explicit IO#close has different ownership semantics, so never install
# this compatibility path on CRuby. Spinner retains TLS and deadline handling.
if RUBY_ENGINE != "ruby"
  module Spinner
    class Transport
      def write_some(bytes, deadline)
        write_stream_chunk(bytes.b, deadline)
      end
    end
    module TLS
      class Socket
        def write_stream_nonblock(bytes)
          binary = bytes.to_s.b
          @io_lock.synchronize do
            if @ssl.nil?
              io = IO.for_fd(@socket.fileno, "wb", autoclose: false)
              begin
                io.write_nonblock(binary.b)
              ensure
                io.close
              end
            else
              write_nonblock_unlocked(bytes)
            end
          end
        end
      end
    end
  end
end
