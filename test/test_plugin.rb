require_relative "helper"
require_relative "helpers/integration"

class TestPlugin < TestIntegration
  def test_plugin
    skip "Skipped on Windows Ruby < 2.5.0, Ruby bug" if windows? && RUBY_VERSION < '2.5.0'
    @tcp_bind = UniquePort.call
    @tcp_ctrl = UniquePort.call

    Dir.mkdir("tmp") unless Dir.exist?("tmp")

    cli_server "-b tcp://#{HOST}:#{@tcp_bind} --control-url tcp://#{HOST}:#{@tcp_ctrl} --control-token #{TOKEN} -C test/config/plugin1.rb test/rackup/hello.ru"
    File.open('tmp/restart.txt', mode: 'wb') { |f| f.puts "Restart #{Time.now}" }

    true while (l = @server.gets) !~ /Restarting\.\.\./
    assert_match(/Restarting\.\.\./, l)

    true while (l = @server.gets) !~ /Ctrl-C/
    assert_match(/Ctrl-C/, l)

    out = StringIO.new

    cli_pumactl "-C tcp://#{HOST}:#{@tcp_ctrl} -T #{TOKEN} stop"
    true while (l = @server.gets) !~ /Goodbye/

    @server.close
    @server = nil
    out.close
  end

  def test_log_stats(clustered: false)
    @tcp_port = UniquePort.call
    uri = URI.parse("tcp://#{HOST}:#{@tcp_port}")

    config = Puma::Configuration.new do |c|
      c.workers 2 if clustered
      c.bind uri.to_s
      c.plugin :log_stats
      c.app do |_|
        sleep Puma::Const::WORKER_CHECK_INTERVAL + 2
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

    true while (log = r.gets.tap(&method(:puts))) && log !~ /{.*}/
    log = log.sub(/^\[\d+\] /, '')
    assert_equal 1, JSON.parse(log)['total']
  ensure
    launcher && launcher.stop
    thread && thread.join
  end

  def test_log_stats_clustered
    test_log_stats(clustered: true)
  end

  private

  def cli_pumactl(argv)
    pumactl = IO.popen("#{BASE} bin/pumactl #{argv}", "r")
    @ios_to_close << pumactl
    Process.wait pumactl.pid
    pumactl
  end
end
