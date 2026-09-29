# frozen_string_literal: true

module RailsAgentConsole
  class CLI
    USAGE = <<~TEXT
      Usage: rails-agent <command>

        configure   Pick a provider and store an API key in ~/.rails_agent_console/config
        schema      Print the schema context the agent sends to the model (needs a Rails app)
        doctor      Show the resolved configuration and check connectivity
        version     Print the gem version
    TEXT

    def initialize(argv, config: RailsAgentConsole.configuration, ui: nil)
      @argv = argv
      @config = config
      @ui = ui || UI.new(config)
    end

    def run
      case @argv.first
      when "configure" then configure
      when "schema" then schema
      when "doctor" then doctor
      when "version", "-v", "--version" then version
      when nil, "help", "-h", "--help" then help
      else
        @ui.failure "Unknown command #{@argv.first.inspect}"
        help
        1
      end
    end

    private

    def configure
      Setup.run(config: @config, ui: @ui) ? 0 : 1
    end

    def schema
      return 1 unless load_rails_app

      @ui.say Schema.context
      0
    end

    def doctor
      @ui.heading "Rails Agent Console #{VERSION}"
      @ui.say "provider:    #{@config.provider}"
      @ui.say "model:       #{@config.model}"
      @ui.say "api key:     #{key_status}"
      @ui.say "config file: #{Credentials.path}#{" (not created yet)" unless Credentials.exist?}"
      @ui.say "mode:        #{@config.write_mode? ? "write" : "read-only"}"
      @ui.blank
      probe
    end

    def probe
      unless @config.api_key?
        @ui.failure "No API key. Run `rails-agent configure`."
        return 1
      end

      answer = Providers.build(@config).chat(
        system: "You are a health check. Answer with the single word: ok",
        messages: [{ role: "user", content: "ping" }]
      )
      @ui.success "#{@config.provider} responded: #{answer.strip[0, 40]}"
      0
    rescue Error => e
      @ui.failure e.message
      1
    end

    def key_status
      return "not set" unless @config.api_key

      env_key = Configuration::ENV_KEYS[@config.provider]
      source = ENV[env_key].to_s.empty? ? "config file" : env_key
      "#{mask(@config.api_key)} (from #{source})"
    end

    def mask(key)
      return "****" if key.to_s.length < 8

      "#{key[0, 3]}#{"*" * 10}#{key[-4, 4]}"
    end

    def load_rails_app
      path = File.expand_path("config/environment.rb", Dir.pwd)
      unless File.exist?(path)
        @ui.failure "No config/environment.rb here - run this from a Rails application root."
        return false
      end

      ENV["RAILS_ENV"] ||= "development"
      require path
      true
    rescue StandardError, LoadError => e
      @ui.failure "Could not load the Rails application: #{e.message}"
      false
    end

    def help
      @ui.say USAGE
      0
    end

    def version
      @ui.say VERSION
      0
    end
  end
end
