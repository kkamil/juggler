require 'juggler/state_machine'

class Juggler
  class JobRunner
    include StateMachine

    state :new
    state :running, :pre => :fetch_stats, :enter => :run_strategy
    state :succeeded, :enter => :delete
    state :timed_out, :enter => [:timeout_strategy, :backoff]
    state :failed, :enter => :delete
    state :retried, :enter => :backoff
    state :done

    attr_reader :job
    attr_reader :params

    def initialize(juggler, job, params, strategy)
      @juggler = juggler
      @job = job
      @params = params
      @strategy = strategy
      logger.debug {
        "#{to_s}: New job with body: #{params.inspect}"
      }
      @_state = :new
    end

    def logger
      @juggler.logger
    end

    def run
      change_state(:running)
    end

    def check_for_timeout
      if state == :running
        if (time_left = @end_time - Time.now) < 1
          logger.info("#{to_s}: Timed out (#{time_left}s left)")
          change_state(:timed_out)
        end
      end
    end

    def to_s
      "Job #{@job.jobid}"
    end

    def release(delay = 0)
      logger.debug { "#{to_s}: releasing" }
      release_def = job.release(:delay => delay)
      release_def.callback {
        logger.info { "#{to_s}: released for retry in #{delay}s" }
        change_state(:done)
      }
      release_def.errback {
        logger.error { "#{to_s}: release failed (could not release)" }
        change_state(:done)
      }
    end

    def bury
      logger.warn { "#{to_s}: burying" }
      release_def = job.bury(100000) # Set priority till em-jack fixed
      release_def.callback {
        change_state(:done)
      }
      release_def.errback {
        change_state(:done)
      }
    end

    def delete
      dd = job.delete
      dd.callback do
        logger.debug "#{to_s}: deleted"
        change_state(:done)
      end
      dd.errback do
        logger.debug "#{to_s}: delete operation failed"
        change_state(:done)
      end
    end

    private

    # Retrives job stats from beanstalkd
    def fetch_stats
      dd = EM::DefaultDeferrable.new

      logger.debug { "#{to_s}: Fetching stats" }

      stats_def = job.stats
      stats_def.callback do |stats|
        @stats = stats
        @end_time = Time.now + stats["time-left"]
        logger.debug { "#{to_s} stats: #{stats.inspect}"}
        dd.succeed
      end
      stats_def.errback {
        logger.error { "#{to_s}: Fetching stats failed" }
        dd.fail
      }

      dd
    end

    # Wraps running the actual job.
    # Returns a deferrable that fails if there is an exception calling the
    # strategy or if the strategy triggers errback
    def run_strategy
      begin
        sd = EM::DefaultDeferrable.new
        @strategy.call(sd, @params, @stats)
        sd.callback {
          change_state(:succeeded)
        }
        sd.errback { |e|
          # timed_out error is already handled
          next if e == :timed_out

          if e == :no_retry
            # Do not schedule the job to be retried
            change_state(:failed)
          elsif e.kind_of?(Exception)
            # Handle exception and schedule for retry
            @juggler.exception_handler.call(e)
            change_state(:retried)
          else
            logger.debug { "#{to_s}: failed with #{e.inspect}" }
            change_state(:retried)
          end
        }
        @strategy_deferrable = sd
      rescue => e
        @juggler.exception_handler.call(e)
        change_state(:retried)
      end
    end

    def timeout_strategy
      @strategy_deferrable.fail(:timed_out)
    end

    def backoff
      @juggler.backoff_function.call(self, @stats)
    end
  end
end
