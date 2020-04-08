require_relative "helper"
require 'puma/configuration'
require "puma/launcher"

class TestPlugin < Minitest::Test
  HOST = "127.0.0.1"

  def setup
    @ios_to_close = []
  end

  def teardown
    @ios_to_close.each {|io| io.close}
  end

  def test_log_stats(clustered: false)
    @tcp_port = UniquePort.call
    uri = URI.parse("tcp://#{HOST}:#{@tcp_port}")

    config = Puma::Configuration.new do |c|
      c.workers 2 if clustered
      c.bind uri.to_s
      c.plugin :log_stats
      c.app do |_|
        sleep 1
        [200, {}, ["Hello"]]
      end
    end
    LogStats.threshold = 1

    r, w = IO.pipe
    events = Puma::Events.new(w, w)
    events.on_booted do
      Thread.new do
        sock = TCPSocket.new(uri.host, uri.port)
        @ios_to_close << sock
        begin
          sock << "GET / HTTP/1.0\r\n\r\n"
        end while sock.gets rescue nil
      end
    end
    launcher = Puma::Launcher.new(config, events: events)
    thread = Thread.new { launcher.run }

    # Keep reading server-log lines until it contains a json object `{}`.
    # Copy output to stdout if debugging (PUMA_DEBUG=1).
    stdio = Puma::Events.stdio
    true while (log = r.gets.tap(&stdio.method(:debug))) && log !~ /{.*}/

    log = log.sub(/^\[\d+\] /, '')
    assert_equal 1, JSON.parse(log)['running']
  ensure
    launcher && launcher.stop
    thread && thread.join
  end

  def test_log_stats_clustered
    test_log_stats(clustered: true)
  end
end
