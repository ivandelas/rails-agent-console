# frozen_string_literal: true

require "rails_agent_console/cli"

RSpec.describe RailsAgentConsole::CLI do
  def run(*argv)
    described_class.new(argv, config: RailsAgentConsole.configuration).run
  end

  around do |example|
    previous = ENV.to_hash
    RailsAgentConsole::Configuration::ENV_KEYS.each_value { |key| ENV.delete(key) }
    Dir.mktmpdir("rails-agent-console-cli") do |dir|
      ENV["RAILS_AGENT_CONSOLE_CONFIG"] = File.join(dir, "config")
      example.run
    end
  ensure
    ENV.replace(previous)
  end

  describe "version" do
    %w[version -v --version].each do |flag|
      it "prints the version for #{flag}" do
        expect(run(flag)).to eq(0)
        expect(printed.strip).to eq(RailsAgentConsole::VERSION)
      end
    end
  end

  describe "help" do
    [nil, "help", "-h", "--help"].each do |flag|
      it "prints usage for #{flag.inspect}" do
        expect(run(*[flag].compact)).to eq(0)
        expect(printed).to include("configure", "schema", "doctor")
      end
    end

    it "explains an unknown command and fails" do
      expect(run("frobnicate")).to eq(1)
      expect(printed).to include("Unknown command \"frobnicate\"")
    end
  end

  describe "doctor" do
    it "reports a missing key and fails" do
      expect(run("doctor")).to eq(1)
      expect(printed).to include("provider:    openai", "api key:     not set", "mode:        read-only")
      expect(printed).to include("No API key")
    end

    it "masks a key from the environment" do
      ENV["OPENAI_API_KEY"] = "sk-abcdefghijklmnop"
      reconfigure { |config| config.client = ->(**_call) { "ok" } }

      expect(run("doctor")).to eq(0)
      expect(printed).to include("sk-**********mnop (from OPENAI_API_KEY)")
      expect(printed).not_to include("sk-abcdefghijklmnop")
    end

    it "says where a stored key came from" do
      RailsAgentConsole::Credentials.store(provider: :openai, api_key: "sk-abcdefghijklmnop")
      reconfigure { |config| config.client = ->(**_call) { "ok" } }

      expect(run("doctor")).to eq(0)
      expect(printed).to include("(from config file)")
    end

    it "pings the provider and reports the answer" do
      RailsAgentConsole.configuration.client = ->(**_call) { "ok" }

      expect(run("doctor")).to eq(0)
      expect(printed).to include("responded: ok")
    end

    it "reports a provider failure and fails" do
      RailsAgentConsole.configuration.client = ->(**_call) { raise RailsAgentConsole::ProviderError, "401 nope" }

      expect(run("doctor")).to eq(1)
      expect(printed).to include("401 nope")
    end

    it "reports write mode when it is on" do
      RailsAgentConsole.configuration.write_mode = true
      RailsAgentConsole.configuration.client = ->(**_call) { "ok" }

      expect(run("doctor")).to eq(0)
      expect(printed).to include("mode:        write")
    end
  end

  describe "configure" do
    before { stub_providers }

    it "stores the chosen provider, model and key" do
      answer_with "2", "1", "", "sk-configured", "", "y"

      expect(run("configure")).to eq(0)

      data = RailsAgentConsole::Credentials.read
      expect(data["default_provider"]).to eq("openai")
      expect(data.dig("openai", "api_key")).to eq("sk-configured")
      expect(data.dig("openai", "model")).to eq("gpt-4o-mini")
    end

    {
      "1" => :openai,
      "2" => :anthropic,
      "3" => :gemini,
      "openai" => :openai,
      "gemini" => :gemini
    }.each do |answer, provider|
      it "accepts #{answer.inspect} as #{provider}" do
        answer_with "2", answer, "", "sk-key", "", "n"

        expect(run("configure")).to eq(0)
        expect(RailsAgentConsole.configuration.provider).to eq(provider)
      end
    end

    it "asks for no key when ollama is chosen" do
      answer_with "1", "", "", "n"

      expect(run("configure")).to eq(0)
      expect(RailsAgentConsole.configuration.provider).to eq(:ollama)
      expect(printed).not_to include("API key:")
    end

    it "keeps the key out of the file when asked not to store it" do
      answer_with "2", "1", "", "sk-not-stored", "", "n"

      expect(run("configure")).to eq(0)
      expect(RailsAgentConsole::Credentials).not_to be_exist
      expect(RailsAgentConsole.configuration.api_key).to eq("sk-not-stored")
    end

    it "accepts a custom model" do
      answer_with "2", "1", "", "sk-key", "gpt-4.1-mini", "y"

      expect(run("configure")).to eq(0)
      expect(RailsAgentConsole.configuration.model).to eq("gpt-4.1-mini")
    end

    it "fails on an unknown provider choice" do
      answer_with "9"

      expect(run("configure")).to eq(1)
      expect(printed).to include("Unknown choice")
    end

    it "fails when no key is entered" do
      answer_with "2", "1", "", ""

      expect(run("configure")).to eq(1)
      expect(printed).to include("No key entered")
    end
  end

  describe "schema" do
    it "explains that it needs a Rails application" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          expect(run("schema")).to eq(1)
        end
      end

      expect(printed).to include("run this from a Rails application root")
    end
  end
end
