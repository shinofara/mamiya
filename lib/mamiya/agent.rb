require 'thread'
require 'villein'
require 'mamiya/version'

require 'mamiya/logger'

require 'mamiya/steps/fetch'
require 'mamiya/agent/task_queue'

require 'mamiya/agent/tasks/fetch'
require 'mamiya/agent/tasks/clean'

require 'mamiya/agent/handlers/task'
require 'mamiya/agent/actions'

module Mamiya
  class Agent
    include Mamiya::Agent::Actions

    def initialize(config, logger: Mamiya::Logger.new, events_only: nil)
      @config = config
      @serf = init_serf
      @events_only = events_only

      @terminate = false

      @logger = logger['agent']
    end

    attr_reader :config, :serf, :logger

    def task_queue
      @task_queue ||= Mamiya::Agent::TaskQueue.new(self, logger: logger, task_classes: [
        Mamiya::Agent::Tasks::Fetch,
        Mamiya::Agent::Tasks::Clean,
      ])
    end

    def run!
      logger.info "Starting..."
      start()
      logger.info "Started."

      loop do
        if @terminate
          terminate
          return
        end
        sleep 1
      end
    end

    def stop!
      @terminate = true
    end

    def start
      serf_start
      task_queue_start
    end

    def terminate
      serf.stop!
      task_queue.stop!
    ensure
      @terminate = false
    end

    def update_tags!
      serf.tags['mamiya'] = ','.tap do |status|
        status.concat('ready,') if status == ','
      end

      nil
    end

    ##
    # Returns agent status. Used for HTTP API and `serf query` inspection.
    def status(packages: true)
      {}.tap do |s|
        s[:name] = serf.name
        s[:version] = Mamiya::VERSION

        s[:queues] = task_queue.status

        s[:packages] = self.existing_packages if packages
      end
    end

    ##
    # Returns hash with existing packages (where valid) by app name.
    # Packages which has json and tarball is considered as valid.
    def existing_packages
      paths_by_app = Dir[File.join(config[:packages_dir], '*', '*.{tar.gz,json}')].group_by { |path|
        path.split('/')[-2]
      }

      Hash[
        paths_by_app.map { |app, paths|
          names_by_base = paths.group_by do |path|
            File.basename(path).sub(/\.(?:tar\.gz|json)\z/, '')
          end

          packages = names_by_base.flat_map { |base, names|
            names.map do |name|
              (
                name.end_with?(".tar.gz") &&
                names.find { |_| _.end_with?(".json") } &&
                base
              ) || nil
            end
          }.compact

          [app, packages.sort]
        }
      ]
    end

    def trigger(type, action: nil, coalesce: true, **payload)
      name = "mamiya:#{type}"
      name << ":#{action}" if action

      serf.event(name, payload.merge(name: self.serf.name).to_json, coalesce: coalesce)
    end

    private

    def init_serf
      agent_config = (config[:serf] && config[:serf][:agent]) || {}
      # agent_config.merge!(log: $stderr)
      Villein::Agent.new(**agent_config).tap do |serf|
        serf.on_user_event do |event|
          user_event_handler(event)
        end

        serf.respond('mamiya:status') do |event|
          self.status.to_json
        end
      end
    end

    def serf_start
      logger.debug "Starting serf"

      @serf.start!
      @serf.auto_stop
      @serf.wait_for_ready

      logger.debug "Serf became ready"
    end

    def task_queue_start
      logger.debug "Starting task_queue"
      task_queue.start!
    end

    def user_event_handler(event)
      user_event, payload = event.user_event, JSON.parse(event.payload)

      return unless user_event.start_with?('mamiya:')
      user_event = user_event.sub(/^mamiya:/, '')

      type, action = user_event.split(/:/, 2)

      return if @events_only && !@events_only.any?{ |_| _ === type }

      class_name = type.capitalize.gsub(/-./) { |_| _[1].upcase }

      logger.debug "Received user event #{type}"
      logger.debug payload.inspect

      if Handlers.const_defined?(class_name)
        handler = Handlers.const_get(class_name).new(self, event)
        meth = action || :run!
        if handler.respond_to?(meth)
          handler.send meth
        else
          logger.debug "Handler #{class_name} doesn't respond to #{meth}, skipping"
        end
      else
        #logger.warn("Discarded event[#{event.user_event}] because we don't handle it")
      end
    rescue Exception => e
      logger.fatal("Error during handling event: #{e.inspect}")
      e.backtrace.each do |line|
        logger.fatal line.prepend("\t")
      end

      raise e if $0.end_with?('rspec')
    rescue JSON::ParserError
      logger.warn("Discarded event[#{event.user_event}] with invalid payload (unable to parse as json)")
    end
  end
end
