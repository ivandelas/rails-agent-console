# frozen_string_literal: true

require_relative "rails_agent_console/version"
require_relative "rails_agent_console/errors"
require_relative "rails_agent_console/configuration"
require_relative "rails_agent_console/credentials"
require_relative "rails_agent_console/ui"
require_relative "rails_agent_console/schema"
require_relative "rails_agent_console/prompt"
require_relative "rails_agent_console/query_validator"
require_relative "rails_agent_console/executor"
require_relative "rails_agent_console/value_check"
require_relative "rails_agent_console/diagnosis"
require_relative "rails_agent_console/history"
require_relative "rails_agent_console/rewriter"
require_relative "rails_agent_console/proposal"
require_relative "rails_agent_console/providers"
require_relative "rails_agent_console/agent"
require_relative "rails_agent_console/wizard"
require_relative "rails_agent_console/setup"
require_relative "rails_agent_console/model_picker"
require_relative "rails_agent_console/console_methods"

# Usage:
#   ai      "How many users registered this month?"  # propose + confirm + run
#   ask     "Why is User.includes(:orders) faster?"  # explain only, never runs
#   explain User.where(active: true)                 # explain an existing query
module RailsAgentConsole
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield configuration if block_given?
      configuration
    end

    alias config configuration

    def agent
      @agent ||= Agent.new
    end

    def history
      agent.history
    end

    def reset!
      @configuration = nil
      @agent = nil
      Schema.reset!
      self
    end
  end
end

require_relative "rails_agent_console/railtie" if defined?(Rails::Railtie)
