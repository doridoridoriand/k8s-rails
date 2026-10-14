# frozen_string_literal: true

require "socket"

# A single-purpose local HTTP server for specs that need to observe what a
# REAL kruby ApiClient sends (e.g. the Authorization header) without a
# cluster. Accepts `requests` connections, records each request's
# Authorization header, and answers 200 with an empty JSON object.
#
# Loopback only — no external network is touched.
class LocalHttpServer
  attr_reader :port, :authorization_headers

  def initialize(requests: 2)
    @requests = requests
    @authorization_headers = []
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
        data = read_headers(io)
        @authorization_headers << data[/^authorization: ([^\r\n]*)\r\n/i, 1]
        write_response(io)
        break if @authorization_headers.size >= @requests
      end
    end
    self
  end

  def stop
    @server.close
    @thread&.join
  end

  private

  def read_headers(io)
    data = ""
    data += io.readpartial(4096) until data.end_with?("\r\n\r\n")
    data
  end

  def write_response(io)
    io.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
  ensure
    io.close
  end
end
