# frozen_string_literal: true

RSpec.describe RailsAgentConsole::Wizard do
  around do |example|
    previous = ENV.to_hash
    RailsAgentConsole::Configuration::ENV_KEYS.each_value { |key| ENV.delete(key) }
    Dir.mktmpdir("rails-agent-console") do |dir|
      ENV["RAILS_AGENT_CONSOLE_CONFIG"] = File.join(dir, "config")
      example.run
    end
  ensure
    ENV.replace(previous)
  end

  let(:config) { RailsAgentConsole.configuration }
  let(:stored) { RailsAgentConsole::Credentials.read }

  before do
    reconfigure
    stub_providers
  end

  def wizard(*answers)
    answer_with(*answers)
    described_class.run(config: config, ui: RailsAgentConsole::UI.new(config))
  end

  describe "on this machine" do
    before { stub_providers(models: ["llama3.2:latest", "qwen2.5-coder:7b"]) }

    it "offers the installed models, recommended first, and asks for no key" do
      expect(wizard("1", "", "2", "y")).to be(true)

      expect(printed).to include("Ollama answers on http://localhost:11434, 2 models installed",
                                 "1. qwen2.5-coder:7b", "2. llama3.2:latest")
      expect(printed).not_to include("API key")
      expect(stored).to include("default_provider" => "ollama", "ollama" => { "model" => "llama3.2:latest" })
    end

    it "remembers an Ollama running somewhere else" do
      wizard("1", "http://gpu-box:11434/", "", "y")

      expect(config.api_base).to eq("http://gpu-box:11434")
      expect(stored.dig("ollama", "base_url")).to eq("http://gpu-box:11434")
    end

    it "says how to start Ollama and what to pull when nothing answers" do
      stub_providers(models: [])

      wizard("1", "", "", "n")

      expect(printed).to include("ollama serve", "ollama pull qwen2.5-coder:7b")
      expect(config.model).to eq("qwen2.5-coder:7b")
    end
  end

  describe "a hosted API" do
    it "uses the key from the environment without asking" do
      ENV["OPENAI_API_KEY"] = "sk-env"
      stub_providers(models: %w[gpt-4.1 gpt-4o gpt-4o-mini])

      wizard("2", "1", "", "", "2", "y")

      expect(printed).to include("Using the key from OPENAI_API_KEY", "1. gpt-4o-mini", "2. gpt-4.1")
      expect(printed).not_to include("sk-env")
      expect(config.model).to eq("gpt-4.1")
      expect(stored.dig("openai", "api_key")).to be_nil
    end

    it "takes another key over the one in the environment, and says the environment wins next time" do
      ENV["OPENAI_API_KEY"] = "sk-env"

      wizard("2", "1", "", "n", "sk-other", "", "y")

      expect(config.api_key).to eq("sk-other")
      expect(printed).to include("Found a key in OPENAI_API_KEY.", "a new session goes back to it")
      expect(printed).not_to include("sk-other", "sk-env")
      expect(stored.dig("openai", "api_key")).to eq("sk-other")
    end

    it "asks for a key, hides it, and stores the typed one" do
      wizard("2", "2", "", "sk-anthropic", "", "y")

      expect(config.provider).to eq(:anthropic)
      expect(config.model).to eq("claude-3-5-sonnet-latest")
      expect(printed).not_to include("sk-anthropic")
      expect(stored.dig("anthropic", "api_key")).to eq("sk-anthropic")
    end

    it "takes any model name when the list cannot be read" do
      wizard("2", "3", "", "gm-key", "gemini-2.5-pro", "n")

      expect(printed).to include("Could not list the models")
      expect(config.model).to eq("gemini-2.5-pro")
    end

    it "shows a long list in part" do
      ENV["OPENAI_API_KEY"] = "sk-env"
      stub_providers(models: (1..20).map { |n| "gpt-4.#{n}" })

      wizard("2", "1", "", "", "", "n")

      expect(printed).to include("15. ", "...and 5 more")
      expect(printed).not_to include("16. ")
    end

    it "keeps everything when Enter is pressed all the way through" do
      ENV["OPENAI_API_KEY"] = "sk-env"

      wizard("", "", "", "", "", "n")

      expect([config.provider, config.model, config.api_base]).to eq([:openai, "gpt-4o-mini", nil])
    end

    it "changes nothing when no key is typed" do
      ENV["OPENAI_API_KEY"] = "sk-env"
      config.model = "gpt-4o"

      expect(wizard("2", "2", "", "")).to be_falsey

      expect([config.provider, config.model]).to eq([:openai, "gpt-4o"])
      expect(printed).to include("No key entered, nothing changed. Still on openai/gpt-4o.")
    end
  end

  describe "an OpenAI-compatible endpoint" do
    it "stores the base URL and its key with the openai settings" do
      wizard("3", "https://openrouter.ai/api/v1/", "sk-or", "meta-llama/llama-3.3-70b", "y")

      expect(config.provider).to eq(:openai)
      expect(config.api_base).to eq("https://openrouter.ai/api/v1")
      expect(stored["openai"]).to eq("api_key" => "sk-or", "model" => "meta-llama/llama-3.3-70b",
                                     "base_url" => "https://openrouter.ai/api/v1")
    end

    it "is what the next session sees as the current place" do
      RailsAgentConsole::Credentials.write("default_provider" => "openai",
                                           "openai" => { "api_key" => "sk-or", "base_url" => "https://gw.acme/v1" })
      reconfigure

      wizard("", "", "", "", "n")

      expect(printed).to include("Base URL [https://gw.acme/v1]:")
      expect(config.api_base).to eq("https://gw.acme/v1")
    end
  end

  describe "the live check" do
    before { ENV["OPENAI_API_KEY"] = "sk-env" }

    it "says how long the model took" do
      wizard("2", "1", "", "", "", "n")

      expect(printed).to match(%r{Checking openai/gpt-4o-mini\.\.\.\n✓ It answered in \d+\.\ds\.})
    end

    it "goes back to the old setup when the model does not answer" do
      stub_providers(answer: RailsAgentConsole::ProviderError.new("OpenAI returned 404: no such model"))
      config.model = "gpt-4o"

      expect(wizard("2", "1", "", "", "gpt-typo", "n")).to be_falsey

      expect(printed).to include("OpenAI returned 404: no such model", "Still on openai/gpt-4o.")
      expect(config.model).to eq("gpt-4o")
    end

    it "keeps it anyway when asked to" do
      stub_providers(answer: RailsAgentConsole::ProviderError.new("timeout"))

      wizard("2", "1", "", "", "gpt-new", "y", "n")

      expect(config.model).to eq("gpt-new")
    end
  end

  it "refuses an answer it does not know" do
    expect(wizard("9")).to be_falsey

    expect(printed).to include("Unknown choice.")
  end
end
