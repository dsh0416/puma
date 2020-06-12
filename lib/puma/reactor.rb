# frozen_string_literal: true

require 'nio'
require 'puma/queue_close' if RUBY_VERSION < '2.3'
require 'timers/group'

module Puma
  # Monitors a collection of IO objects, calling a block whenever
  # any monitored object either receives data or times out, or when the Reactor shuts down.
  #
  # The waiting/wake up is performed with nio4r, which will use the appropriate backend (libev,
  # Java NIO or just plain IO#select). The call to `NIO::Selector#select` will
  # 'wakeup' any IO object that receives data.
  #
  # This class additionally tracks a timeout for every added object,
  # and wakes up any object when its timeout elapses.
  #
  # The implementation uses a Queue to synchronize adding new objects from the internal select loop.
  class Reactor
    # Create a new Reactor to monitor IO objects added by #add.
    # The provided block will be invoked when an IO has data available to read,
    # its timeout elapses, or when the Reactor shuts down.
    def initialize(&block)
      @selector = NIO::Selector.new
      @input = Queue.new
      @timers = Timers::Group.new
      @timeouts = {}
      @block = block
    end

    # Run the internal select loop, using a background thread by default.
    def run(background=true)
      if background
        @thread = Thread.new do
          Puma.set_thread_name "reactor"
          select_loop
        end
      else
        select_loop
      end
    end

    # Add a new IO object to monitor.
    # The object must respond to #timeout.
    def add(io)
      @input << io
      @selector.wakeup
    rescue ClosedQueueError
      @block.call(io)
    end

    # Shutdown the reactor, blocking until the background thread is finished.
    def shutdown
      @input.close
      @selector.wakeup
      @thread.join if @thread
    end

    private

    def select_loop
      begin
        until @input.closed? && @input.empty?
          unless (interval = @timers.wait_interval).to_f < 0
            @selector.select(interval) {|mon| wakeup!(mon.value)}
          end
          @timers.fire
          register(@input.pop) until @input.empty?
        end
      rescue StandardError => e
        STDERR.puts "Error in reactor loop escaped: #{e.message} (#{e.class})"
        STDERR.puts e.backtrace
        retry
      end
      # Wakeup all remaining objects on shutdown.
      @timers.each(&:fire)
      @selector.close
    end

    # Start monitoring the object.
    def register(io)
      @selector.register(io, :r).value = io
      @timeouts[io] = @timers.after(io.timeout) {wakeup!(io)}
    end

    # 'Wake up' a monitored object by calling the provided block.
    # Stop monitoring the object if the block returns `true`.
    def wakeup!(io)
      if @block.call(io)
        @selector.deregister(io)
        @timeouts[io].cancel
      end
    end
  end
end
