require 'async/reactor'

module Puma
  # Runs an Async::Reactor in a separate thread.
  class Reactor < Async::Reactor
    def initialize
      super
      @stopping = false
      @thread = Thread.new do
        Puma.set_thread_name "reactor"
        run {Async::Task.yield}
      end
    end

    # Schedule an asynchronous task to run on the Reactor thread.
    # Returns `true` if scheduling is successful, or `nil` if the
    # Reactor has already been stopped.
    def async(&block)
      unless @stopping
        later {super}
        true
      end
    end

    # Stop the Reactor and wait for the running thread to finish.
    def stop(*args)
      @stopping = true
      later {super}
      @thread.join
    end

    private

    Later = Struct.new(:block) do
      def alive?; true end
      def resume; block.call end
    end

    # Schedules the provided block to be run on the Reactor thread
    # on the next loop through the reactor.
    def later(&block)
      self << Later.new(block)
      @selector.wakeup
    end
  end
end
