require_relative "helper"

require "puma/configuration"
require 'puma/events'

class TestLauncher < Minitest::Test
  def test_puma_stats
    $stdout.sync = true
    puts '1'
    conf = Puma::Configuration.new {|c| c.clear_binds!}
    puts '2'
    launcher = launcher(conf)
    puts '3'
    launcher.events.on_booted do
      puts '1a'
      launcher.stop
      puts '2a'
    end
    puts '4'
    launcher.run
    puts '5'
    Puma::Server::STAT_METHODS.each do |stat|
      assert_includes Puma.stats, stat
    end
    puts '6'
  rescue => e
    puts "Error: #{e}\n#{e.backtrace.join("\n")}"
    raise
  end

  private

  def events
    @events ||= Puma::Events.strings
  end

  def launcher(config = Puma::Configuration.new, evts = events)
    @launcher ||= Puma::Launcher.new(config, events: evts)
  end
end
