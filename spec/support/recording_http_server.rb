# frozen_string_literal: true

require "socket"

# A loopback HTTP server that RECORDS what a request actually looks like on
# the wire (method, path, Content-Type, Authorization, body) and serves
# canned responses in order. Built for the boundary-condition regression
# layer (#34): specs drive the REAL kruby ApiClient (typhoeus/libcurl
# pipeline) against this server to pin URL normalization, HTTP methods,
# Content-Type negotiation, auth headers, response deserialization and error
# conversion — with no cluster and no external network touched.
class RecordingHttpServer
  Entry = Struct.new(:http_method, :path, :content_type, :authorization, :body)

  attr_reader :port, :entries

  # `requests` bounds the server's lifetime (it stops after that many
  # requests), matching the LocalHttpServer convention. `responses` is a
  # list of {status:, body:} consumed per request; missing entries default
  # to 200 with an empty JSON object.
  def initialize(requests:, responses: [])
    @requests = requests
    @responses = responses
    @entries = []
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
        record(io)
        break if @entries.size >= @requests
      end
    end
    # The server thread must be BLOCKED inside accept before the first
    # request is issued. If the client's request starts while the server
    # thread is still runnable-but-unscheduled, the request thread enters
    # typhoeus's curl_easy_perform and the server thread never gets a chance
    # to accept/respond — the client (timeout 0) then waits forever. Wait
    # until the thread reports "sleep" (= parked in accept) before returning.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    Thread.pass until @thread.status == "sleep" || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    self
  end

  def stop
    @server.close
    @thread&.join
  end

  def last
    @entries.last
  end

  private

  def record(io)
    request_line, headers, partial_body = parse_request(io)
    method, path, = request_line.split(" ")
    body = complete_body(headers, partial_body, io)
    @entries << Entry.new(method, path, headers["content-type"], headers["authorization"], body)
    write_response(io)
  ensure
    begin
      io&.close
    rescue IOError, Errno::EPIPE
      nil
    end
  end

  # A request's header block ENDS at the first "\r\n\r\n", but for requests
  # with a body (POST/PATCH) that boundary is followed by the body IN THE
  # SAME chunk — so the accumulated string does NOT end with "\r\n\r\n".
  # Split on the boundary as it arrives; complete_body() handles the rest.
  def parse_request(io)
    head = ""
    head += io.readpartial(4096) until head.include?("\r\n\r\n")
    header_part, _, partial_body = head.partition("\r\n\r\n")
    [header_part.split("\r\n").first, parse_headers(header_part), partial_body]
  end

  def parse_headers(header_part)
    headers = {}
    header_part.split("\r\n").drop(1).each do |line|
      key, value = line.split(":", 2)
      headers[key.strip.downcase] = value.strip
    end
    headers
  end

  # libcurl writes the body as part of the same stream; the headers chunk
  # may already carry part of it, the rest is Content-Length bytes more.
  def complete_body(headers, partial_body, io)
    length = headers["content-length"].to_i
    body = partial_body
    body += io.read(length - body.bytesize) if body.bytesize < length
    body
  end

  def write_response(io)
    response = @responses.empty? ? { status: 200, body: "{}" } : @responses.shift
    io.write(
      "HTTP/1.1 #{response[:status]} K8SRAILS\r\n" \
      "Content-Type: application/json\r\n" \
      "Content-Length: #{response[:body].bytesize}\r\n" \
      "Connection: close\r\n\r\n#{response[:body]}"
    )
  end
end
