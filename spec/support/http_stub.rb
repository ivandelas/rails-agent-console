# frozen_string_literal: true

require "socket"

module HTTPStub
  Exchange = Struct.new(:path, :headers, :body, keyword_init: true)

  def serve(response, status: 200, raw: false)
    server = TCPServer.new("127.0.0.1", 0)
    payload = raw ? response.to_s : JSON.generate(response)
    captured = nil

    thread = Thread.new do
      socket = server.accept
      captured = read_request(socket)
      write_response(socket, payload, status)
      socket.close
    end

    result = yield "http://127.0.0.1:#{server.addr[1]}"
    thread.join(5)
    [captured, result]
  ensure
    thread&.kill
    server&.close
  end

  def serve_in_turn(responses)
    server = TCPServer.new("127.0.0.1", 0)
    captured = []

    thread = Thread.new do
      responses.each do |response, status|
        socket = server.accept
        captured << read_request(socket)
        write_response(socket, JSON.generate(response), status || 200)
        socket.close
      end
    end

    result = yield "http://127.0.0.1:#{server.addr[1]}"
    thread.join(5)
    [captured, result]
  ensure
    thread&.kill
    server&.close
  end

  def dead_url
    "http://127.0.0.1:1"
  end

  private

  def read_request(socket)
    path = socket.gets.to_s.split[1]
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      key, value = line.split(":", 2)
      headers[key.to_s.downcase] = value.to_s.strip
    end
    raw_body = socket.read(headers["content-length"].to_i).to_s
    Exchange.new(path: path, headers: headers, body: raw_body.empty? ? {} : JSON.parse(raw_body))
  end

  def write_response(socket, payload, status)
    socket.print [
      "HTTP/1.1 #{status} #{status == 200 ? "OK" : "Error"}",
      "Content-Type: application/json",
      "Content-Length: #{payload.bytesize}",
      "Connection: close",
      "",
      payload
    ].join("\r\n")
  end
end
