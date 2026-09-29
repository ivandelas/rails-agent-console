# frozen_string_literal: true

RSpec.describe RailsAgentConsole::ModelPicker do
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
  let(:installed) { ["qwen2.5-coder:7b", "llama3.2:latest"] }

  before do
    ENV["OPENAI_API_KEY"] = "sk-test-key"
    reconfigure
    config.client = nil
    stub_providers(models: installed)
  end

  def pick(target = nil)
    described_class.run(target, config: config, ui: RailsAgentConsole::UI.new(config))
  end

  def typed_into_console
    allow(RailsAgentConsole::Setup).to receive(:interactive?).and_return(true)
  end

  describe "with no argument" do
    it "marks the provider in use and says where its key comes from" do
      pick

      expect(printed).to include("openai/gpt-4o-mini", "* openai", "key from OPENAI_API_KEY")
    end

    it "lists the other providers with their default models" do
      pick

      expect(printed).to include("anthropic", "claude-3-5-sonnet-latest", "gemini-2.0-flash", "qwen2.5-coder:7b")
    end

    it "shows the model actually in use, not the default one" do
      config.model = "gpt-4o"

      pick

      expect(printed).to include("* openai     gpt-4o ")
      expect(printed).not_to include("gpt-4o-mini")
    end

    it "shows the model stored for another provider" do
      RailsAgentConsole::Credentials.write("ollama" => { "model" => "llama3.2" })

      pick

      expect(printed).to include("  ollama     llama3.2 ")
    end

    it "says which providers have no key, and that Ollama needs none" do
      pick

      expect(printed).to include("no key (set ANTHROPIC_API_KEY)", "needs Ollama on http://localhost:11434")
    end

    it "never prints the key itself" do
      pick

      expect(printed).not_to include("sk-test-key")
    end
  end

  describe "the guided change" do
    before { typed_into_console }

    it "changes nothing unless asked to" do
      answer_with ""

      pick

      expect(config.model).to eq("gpt-4o-mini")
      expect(printed).not_to include("Where should the model run?")
    end

    it "hands over to the wizard" do
      answer_with "y", "1", "", "", "n"

      pick

      expect(printed).to include("Where should the model run?")
      expect(config.provider).to eq(:ollama)
    end
  end

  describe "with a model" do
    it "keeps the provider for a model it does not recognise" do
      pick "ft:gpt-4o-mini:acme"

      expect(config.provider).to eq(:openai)
      expect(config.model).to eq("ft:gpt-4o-mini:acme")
      expect(printed).to include("Now using openai/ft:gpt-4o-mini:acme.")
    end

    it "moves to the provider the name belongs to" do
      config.provider = :ollama

      pick "gpt-4o"

      expect(config.provider).to eq(:openai)
      expect(config.model).to eq("gpt-4o")
      expect(printed).to include("Now using openai/gpt-4o.")
    end

    it "keeps a name it does not recognise on Ollama" do
      config.provider = :ollama

      pick "llama3.2"

      expect(config.provider).to eq(:ollama)
      expect(config.model).to eq("llama3.2")
    end

    it "asks for the key when the name belongs to a provider without one" do
      typed_into_console
      answer_with "sk-anthropic", "n"

      pick "claude-sonnet-4-5"

      expect(config.provider).to eq(:anthropic)
      expect(config.model).to eq("claude-sonnet-4-5")
      expect(config.api_key).to eq("sk-anthropic")
    end

    it "keeps a key typed earlier in the session when only the model changes" do
      config.api_key = "sk-typed"

      pick "gpt-4o"

      expect(config.api_key).to eq("sk-typed")
    end

    it "builds a new client for the next call" do
      built_at_boot = RailsAgentConsole.agent.provider

      pick "gpt-4o"

      expect(RailsAgentConsole.agent.provider).not_to be(built_at_boot)
    end
  end

  describe "with a provider" do
    it "switches both when the model is spelled out" do
      pick "ollama/llama3.2"

      expect(config.provider).to eq(:ollama)
      expect(config.model).to eq("llama3.2")
    end

    it "falls back to the provider's default model" do
      pick "ollama"

      expect(config.model).to eq("qwen2.5-coder:7b")
    end

    it "stays where it was when the new provider has no key" do
      pick "anthropic"

      expect(config.provider).to eq(:openai)
      expect(config.model).to eq("gpt-4o-mini")
      expect(printed).to include("No key for anthropic (set ANTHROPIC_API_KEY", "stays on openai/gpt-4o-mini.")
    end

    it "refuses an Ollama model that is not installed" do
      pick "ollama/mistral"

      expect(config.provider).to eq(:openai)
      expect(printed).to include("mistral is not installed in Ollama. Installed: qwen2.5-coder:7b, llama3.2:latest",
                                 "ollama pull mistral")
    end

    it "switches anyway when Ollama cannot be asked, and says how to start it" do
      stub_providers(models: [])

      pick "ollama/mistral"

      expect(config.model).to eq("mistral")
      expect(printed).to include("ollama serve")
    end

    it "can store the choice as the default" do
      typed_into_console
      answer_with "y"

      pick "ollama"

      expect(RailsAgentConsole::Credentials.read)
        .to include("default_provider" => "ollama", "ollama" => hash_including("model" => "qwen2.5-coder:7b"))
    end

    it "stores a typed key but never one that came from the environment" do
      typed_into_console
      answer_with "y"

      pick "gpt-4o"

      expect(RailsAgentConsole::Credentials.read.dig("openai", "api_key")).to be_nil
    end

    it "stores the key typed for a new provider" do
      typed_into_console
      answer_with "sk-anthropic", "y"

      pick "anthropic"

      expect(RailsAgentConsole::Credentials.read.dig("anthropic", "api_key")).to eq("sk-anthropic")
    end
  end

  it "refuses a provider it does not know" do
    pick "openai-5/turbo"

    expect(config.provider).to eq(:openai)
    expect(printed).to include('"openai-5/turbo" names no provider. Known: openai, anthropic, gemini, ollama.')
  end

  describe "Configuration.provider_for" do
    {
      "gpt-4o" => :openai, "gpt-4.1-mini" => :openai, "o3-mini" => :openai, "o1" => :openai,
      "claude-sonnet-4-5" => :anthropic, "gemini-2.5-pro" => :gemini,
      "gpt-oss:20b" => nil, "llama3.2" => nil, "qwen2.5-coder:7b" => nil
    }.each do |name, owner|
      it "reads #{name.inspect} as #{owner.inspect}" do
        expect(RailsAgentConsole::Configuration.provider_for(name)).to eq(owner)
      end
    end
  end
end
