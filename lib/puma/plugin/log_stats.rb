require 'puma'
require 'puma/plugin'
require 'json'

# Puma plugin to log stats whenever the number of
# total pending requests exceeds a configured threshold.
module LogStats
  class << self
    # Minimum pending requests that will trigger logging app stats
    # or nil to disable logging.
    # If this attribute is a Proc, it will be evaluated each access.
    attr_accessor :threshold
  end

  Puma::Plugin.create do
    def start(launcher)
      in_background do
        loop do
          begin
            sleep launcher.options[:worker_check_interval]
            min = LogStats.threshold
            min = min.call if min.is_a?(Proc)
            if min
              stats = launcher.stats
              stats = JSON.parse(stats, symbolize_names: true) if stats.is_a?(String)
              total = if stats[:worker_status]
                stats[:worker_status].map {|w| pending(w[:last_status])}.inject(&:+)
              else
                pending(stats)
              end
              if total >= min
                stats[:total] = total
                launcher.events.log stats.to_json
              end
            end
          rescue => e
            launcher.events.log "LogStats failed: #{e}\n  #{e.backtrace.join("\n    ")}"
          end
        end
      end
    end

    private

    def pending(stats)
      return 0 unless stats
      stats[:max_threads].to_i - stats[:pool_capacity].to_i + stats[:backlog].to_i
    end
  end
end
