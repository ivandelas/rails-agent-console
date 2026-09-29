# frozen_string_literal: true

RSpec.describe RailsAgentConsole::Configuration do
  around do |example|
    previous = ENV.to_hash
    described_class::ENV_KEYS.each_value { |key| ENV.delete(key) }
    Dir.mktmpdir("rails-agent-console") do |dir|
      ENV["RAILS_AGENT_CONSOLE_CONFIG"] = File.join(dir, "config")
      example.run
    end
  ensure
    ENV.replace(previous)
  end

  def config
    RailsAgentConsole.reset!
    RailsAgentConsole.configuration
  end

  describe "defaults" do
    it "uses OpenAI in read-only mode" do
      expect(config.provider).to eq(:openai)
      expect(config.model).to eq("gpt-4o-mini")
      expect(config).not_to be_write_mode
      expect(config).not_to be_auto_confirm
    end

    it "installs every console helper" do
      expect(config.console_helpers).to include(:ai, :ai!, :ask, :explain, :run)
    end
  end

  describe "provider detection from the environment" do
    {
      "OPENAI_API_KEY" => [:openai, "gpt-4o-mini"],
      "ANTHROPIC_API_KEY" => [:anthropic, "claude-3-5-sonnet-latest"],
      "GEMINI_API_KEY" => [:gemini, "gemini-2.0-flash"]
    }.each do |env_key, (provider, model)|
      it "picks #{provider} from #{env_key}" do
        ENV[env_key] = "key-for-#{provider}"

        expect(config.provider).to eq(provider)
        expect(config.api_key).to eq("key-for-#{provider}")
        expect(config.model).to eq(model)
      end
    end

    it "ignores blank values" do
      ENV["OPENAI_API_KEY"] = "   "

      expect(config.api_key).to be_nil
      expect(config).not_to be_api_key
    end
  end

  describe "key precedence" do
    it "prefers an explicit key over everything" do
      RailsAgentConsole::Credentials.store(provider: :openai, api_key: "from-file")
      ENV["OPENAI_API_KEY"] = "from-env"
      configuration = config
      configuration.api_key = "explicit"

      expect(configuration.api_key).to eq("explicit")
    end

    it "prefers the environment over the stored key" do
      RailsAgentConsole::Credentials.store(provider: :openai, api_key: "from-file")
      ENV["OPENAI_API_KEY"] = "from-env"

      expect(config.api_key).to eq("from-env")
    end

    it "forgets the key and the model when the provider changes" do
      ENV["OPENAI_API_KEY"] = "from-env"
      configuration = config
      expect(configuration.api_key).to eq("from-env")

      configuration.provider = :anthropic

      expect(configuration.api_key).to be_nil
      expect(configuration.model).to eq("claude-3-5-sonnet-latest")
    end

    it "falls back to the stored key" do
      RailsAgentConsole::Credentials.store(provider: :gemini, api_key: "from-file", model: "gemini-1.5-pro")

      expect(config.provider).to eq(:gemini)
      expect(config.api_key).to eq("from-file")
      expect(config.model).to eq("gemini-1.5-pro")
    end
  end

  describe "#api_key?" do
    it "is satisfied by a custom client" do
      configuration = config
      configuration.client = ->(**_call) { "{}" }

      expect(configuration).to be_api_key
      expect(configuration.validate!).to be(true)
    end

    it "is satisfied by ollama without a key" do
      configuration = config
      configuration.provider = :ollama

      expect(configuration).to be_api_key
    end
  end

  describe "#validate!" do
    it "explains a missing key" do
      expect { config.validate! }
        .to raise_error(RailsAgentConsole::ConfigurationError, /OPENAI_API_KEY.*rails-agent configure/m)
    end

    it "rejects an unknown provider" do
      configuration = config
      configuration.provider = :hal9000

      expect { configuration.validate! }.to raise_error(RailsAgentConsole::ConfigurationError, /Unknown provider/)
    end
  end

  describe "#color?" do
    it "follows the output stream when unset" do
      configuration = config
      configuration.output = StringIO.new
      configuration.color = nil

      expect(configuration).not_to be_color
    end

    it "can be forced on" do
      configuration = config
      configuration.color = true

      expect(configuration).to be_color
    end
  end
end
