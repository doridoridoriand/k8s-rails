# frozen_string_literal: true

require "socket"

# A loopback HTTP server that DELAYS each response, for specs that exercise a
# real client-side timeout (issue #33): a finite configured timeout must abort
# the request BEFORE the delayed response arrives, and the failure must
# surface as K8sRails::Unavailable on both Resource operations and the
# `connected?` probe. Loopback only — no external network is touched.
class SlowResponseServer
  attr_reader :port

  def initialize(delay:, requests: 2)
    @delay = delay
    @requests = requests
    @handled = 0
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
  end

  def start
    @thread = Thread.new do
      loop do
        io = begin
          @server.accept
        rescue IOError
          break # stop() closed the server
        end
        handle(io)
        @handled += 1
        break if @handled >= @requests
      end
    end
    self
  end

  def stop
    @server.close
    @thread&.join
  end

  private

  def handle(io)
    data = ""
    data += io.readpartial(4096) until data.end_with?("\r\n\r\n")
    sleep(@delay) # the client's finite timeout aborts before this lands
    io.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
  rescue Errno::EPIPE, IOError
    # the request was abandoned client-side (timed out) — nothing to answer
  ensure
    begin
      io&.close
    rescue IOError, Errno::EPIPE
      nil
    end
  end
end
