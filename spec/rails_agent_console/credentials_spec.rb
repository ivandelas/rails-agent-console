# frozen_string_literal: true

RSpec.describe RailsAgentConsole::Credentials do
  around do |example|
    previous = ENV.to_hash
    RailsAgentConsole::Configuration::ENV_KEYS.each_value { |key| ENV.delete(key) }
    Dir.mktmpdir("rails-agent-console-credentials") do |dir|
      ENV["RAILS_AGENT_CONSOLE_CONFIG"] = File.join(dir, "nested", "config")
      example.run
    end
  ensure
    ENV.replace(previous)
  end

  it "writes a private file, creating the directory on the way" do
    path = described_class.store(provider: :openai, api_key: "sk-test", model: "gpt-4o")

    expect(format("%o", File.stat(path).mode & 0o777)).to eq("600")
    expect(described_class.read).to include("default_provider" => "openai")
  end

  it "merges providers instead of replacing them" do
    described_class.store(provider: :openai, api_key: "sk-openai")
    described_class.store(provider: :anthropic, api_key: "sk-anthropic")

    data = described_class.read
    expect(data.dig("openai", "api_key")).to eq("sk-openai")
    expect(data.dig("anthropic", "api_key")).to eq("sk-anthropic")
    expect(data["default_provider"]).to eq("anthropic")
  end

  it "keeps the stored model when only the key changes" do
    described_class.store(provider: :openai, api_key: "one", model: "gpt-4o")
    described_class.store(provider: :openai, api_key: "two")

    expect(described_class.read.dig("openai", "model")).to eq("gpt-4o")
  end

  it "stores a model without a key for local providers" do
    described_class.store(provider: :ollama, model: "llama3.1")

    expect(described_class.read["ollama"]).to eq("model" => "llama3.1")
  end

  it "ignores a corrupt file" do
    described_class.store(provider: :openai, api_key: "sk-test")
    File.write(described_class.path, "\tnot: yaml: at all\n  -")

    expect(described_class.read).to be_empty
  end

  it "ignores a file that is not a mapping" do
    described_class.store(provider: :openai, api_key: "sk-test")
    File.write(described_class.path, "- just\n- a list\n")

    expect(described_class.read).to be_empty
  end

  it "reports an absent file" do
    expect(described_class).not_to be_exist
    expect(described_class.read).to eq({})
  end

  it "deletes the file" do
    described_class.store(provider: :openai, api_key: "sk-test")
    described_class.delete!

    expect(described_class).not_to be_exist
  end

  it "does not delete anything that is not there" do
    expect { described_class.delete! }.not_to raise_error
  end
end
