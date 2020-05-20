# frozen_string_literal: true

require 'nio'
require 'puma/queue_close'
require 'set'
SortedSet.new if RUBY_VERSION < '2.5' # Ruby bug #13735

module Puma
  # Monitors a collection of IO objects, passing objects to a
  # block whenever data is available for reading or a timeout is reached.
  class Reactor
    def initialize(&block)
      @selector = NIO::Selector.new
      @input = Queue.new
      @ios = SortedSet.new
      @block = block
    end

    def run(background=true)
      if background
        @thread = Thread.new do
          Puma.set_thread_name "reactor"
          reactor_loop
        end
      else
        reactor_loop
      end
    end

    def add(io, timeout_in)
      @input << [timeout_in + now, io]
      @selector.wakeup
    rescue ClosedQueueError
      @block.call(io, timeout_in)
    end

    def shutdown
      @input.close
      @selector.wakeup
      @thread.join if @thread
    end

    private

    def reactor_loop
      until @input.closed? && @input.empty?
        timeout = (timeout_at, _ = @ios.first) && [0, timeout_at - now].max
        select(timeout, &method(:wakeup!))
        timeout!(&method(:wakeup!))
        register @input.pop until @input.empty?
      end
      @ios.each(&method(:wakeup!))
    rescue StandardError => e
      STDERR.puts "Error in reactor loop escaped: #{e.message} (#{e.class})"
      STDERR.puts e.backtrace
      retry
    end

    def select(timeout, &block)
      @selector.select(timeout) { |mon| yield mon.value }
    rescue IOError => e
      Thread.current.purge_interrupt_queue if Thread.current.respond_to? :purge_interrupt_queue
      if (closed = @ios.select {|_, io| io.closed?}).any?
        STDERR.puts "Error in select: #{e.message} (#{e.class})"
        STDERR.puts e.backtrace
        closed.each(&block)
        retry
      else
        raise
      end
    end

    def timeout!(&block)
      @ios.take_while {|timeout_at, _| timeout_at < now}.each(&block)
    end

    def register(obj)
      @ios << @selector.register(obj.last, :r).value = obj
    rescue IOError
      # IO is closed so ignore this request entirely
    end

    def wakeup!(obj)
      timeout, io = obj
      if @block.call(io, [0, timeout - now].max)
        @ios.delete obj
        @selector.deregister io
      end
    rescue IOError
      # nio4r on jruby throws an IOError if the IO is closed, so swallow it.
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
