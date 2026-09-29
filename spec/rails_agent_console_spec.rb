# frozen_string_literal: true

require "rails_agent_console/console_session"

RSpec.describe RailsAgentConsole do
  it "has a version number" do
    expect(described_class::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end

  describe ".configure" do
    it "yields the configuration and keeps it" do
      described_class.configure { |config| config.write_mode = true }

      expect(described_class.configuration).to be_write_mode
      expect(described_class.config).to be(described_class.configuration)
    end
  end

  describe ".agent" do
    it "is memoized together with its history" do
      expect(described_class.agent).to be(described_class.agent)
      expect(described_class.history).to be(described_class.agent.history)
    end
  end

  describe ".reset!" do
    it "drops the agent, the configuration and the schema cache" do
      agent = described_class.agent
      described_class.configuration.write_mode = true
      models = RailsAgentConsole::Schema.models

      described_class.reset!

      expect(described_class.agent).not_to be(agent)
      expect(described_class.configuration).not_to be_write_mode
      expect(RailsAgentConsole::Schema.models).not_to be(models)
    end
  end

  describe RailsAgentConsole::Setup do
    it "does not consider a StringIO interactive" do
      expect(described_class.interactive?).to be(false)
    end

    it "knows when a key is missing" do
      expect(described_class).to be_needed
    end

    it "knows when nothing is needed" do
      RailsAgentConsole.configuration.client = ->(**_call) { "{}" }

      expect(described_class).not_to be_needed
    end
  end

  describe RailsAgentConsole::ConsoleSession do
    it "prints the banner when it is enabled" do
      RailsAgentConsole.configuration.banner = true
      RailsAgentConsole.configuration.client = ->(**_call) { "{}" }

      described_class.start

      expect(printed).to include("Rails Agent Console #{RailsAgentConsole::VERSION}", "read-only")
    end

    it "offers ai_model in the banner, naming what else could answer" do
      RailsAgentConsole.configuration.banner = true
      RailsAgentConsole.configuration.client = ->(**_call) { "{}" }

      described_class.start

      expect(printed).to include("ai_model  to switch model or provider", "ollama")
    end

    it "says WRITE MODE in the banner when write mode is on" do
      RailsAgentConsole.configuration.banner = true
      RailsAgentConsole.configuration.write_mode = true
      RailsAgentConsole.configuration.client = ->(**_call) { "{}" }

      described_class.start

      expect(printed).to include("WRITE MODE")
    end

    it "points at the CLI when no key is configured and the session is not interactive" do
      RailsAgentConsole.configuration.setup_on_boot = true

      described_class.start

      expect(printed).to include("no API key found. Run `rails-agent configure`")
    end

    it "stays quiet when setup_on_boot is off" do
      described_class.start

      expect(printed).to be_empty
    end
  end
end
