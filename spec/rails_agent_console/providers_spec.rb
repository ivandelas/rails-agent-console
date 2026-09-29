# frozen_string_literal: true

require "support/http_stub"

RSpec.describe RailsAgentConsole::Providers do
  include HTTPStub

  SYSTEM_PROMPT = "schema here"
  MESSAGES = [{ role: "user", content: "count customers" }].freeze

  PROVIDERS = {
    openai: {
      klass: RailsAgentConsole::Providers::OpenAI,
      label: "OpenAI",
      default_model: "gpt-4o-mini",
      api_key: "sk-openai",
      success: { choices: [{ message: { content: "answer text" } }] },
      empty: { choices: [{ message: { content: "" } }] },
      path: "/chat/completions",
      auth: ->(exchange) { expect(exchange.headers["authorization"]).to eq("Bearer sk-openai") },
      request: lambda { |exchange|
        expect(exchange.body["model"]).to eq("gpt-4o-mini")
        expect(exchange.body["messages"].first).to eq("role" => "system", "content" => SYSTEM_PROMPT)
        expect(exchange.body["messages"].last["content"]).to eq("count customers")
      }
    },
    anthropic: {
      klass: RailsAgentConsole::Providers::Anthropic,
      label: "Anthropic",
      default_model: "claude-3-5-sonnet-latest",
      api_key: "sk-anthropic",
      success: { content: [{ type: "text", text: "answer text" }] },
      empty: { content: [] },
      path: "/messages",
      auth: lambda { |exchange|
        expect(exchange.headers["x-api-key"]).to eq("sk-anthropic")
        expect(exchange.headers["anthropic-version"]).to eq("2023-06-01")
      },
      request: lambda { |exchange|
        expect(exchange.body["system"]).to eq(SYSTEM_PROMPT)
        expect(exchange.body["messages"].size).to eq(1)
        expect(exchange.body["max_tokens"]).to be_positive
      }
    },
    gemini: {
      klass: RailsAgentConsole::Providers::Gemini,
      label: "Gemini",
      default_model: "gemini-2.0-flash",
      api_key: "gemini-key",
      success: { candidates: [{ content: { parts: [{ text: "answer text" }] } }] },
      empty: { candidates: [{ content: { parts: [] } }] },
      path: "/models/gemini-2.0-flash:generateContent",
      auth: ->(exchange) { expect(exchange.path).to include("key=gemini-key") },
      request: lambda { |exchange|
        expect(exchange.body.dig("system_instruction", "parts", 0, "text")).to eq(SYSTEM_PROMPT)
        expect(exchange.body.dig("contents", 0, "role")).to eq("user")
      }
    },
    ollama: {
      klass: RailsAgentConsole::Providers::Ollama,
      label: "Ollama",
      default_model: "qwen2.5-coder:7b",
      api_key: nil,
      success: { message: { content: "answer text" } },
      empty: { message: { content: "  " } },
      path: "/api/chat",
      auth: ->(exchange) { expect(exchange.headers).not_to have_key("authorization") },
      request: lambda { |exchange|
        expect(exchange.body["stream"]).to be(false)
        expect(exchange.body["messages"].first["role"]).to eq("system")
        expect(exchange.body["options"]).to include("num_ctx" => 8192, "num_predict" => 1024)
      }
    }
  }.freeze

  def configure(name, url, api_key:, model: nil)
    RailsAgentConsole.configure do |config|
      config.provider = name
      config.api_base = url
      config.api_key = api_key
      config.model = model if model
      config.client = nil
    end
  end

  def chat
    described_class.build.chat(system: SYSTEM_PROMPT, messages: MESSAGES)
  end

  PROVIDERS.each do |name, provider|
    describe "#{provider[:label]} provider" do
      it "is built for provider #{name.inspect}" do
        configure(name, nil, api_key: provider[:api_key])

        expect(described_class.build).to be_a(provider[:klass])
      end

      it "defaults to #{provider[:default_model]}" do
        configure(name, nil, api_key: provider[:api_key])

        expect(RailsAgentConsole.configuration.model).to eq(provider[:default_model])
      end

      it "posts to #{provider[:path]} and returns the assistant text" do
        exchange, answer = serve(provider[:success]) do |url|
          configure(name, url, api_key: provider[:api_key])
          chat
        end

        expect(answer.strip).to eq("answer text")
        expect(exchange.path).to include(provider[:path])
      end

      it "authenticates the way the API expects" do
        exchange, = serve(provider[:success]) do |url|
          configure(name, url, api_key: provider[:api_key])
          chat
        end

        instance_exec(exchange, &provider[:auth])
      end

      it "sends the system prompt and the conversation" do
        exchange, = serve(provider[:success]) do |url|
          configure(name, url, api_key: provider[:api_key])
          chat
        end

        instance_exec(exchange, &provider[:request])
      end

      it "reports an empty answer as an invalid response" do
        expect do
          serve(provider[:empty]) do |url|
            configure(name, url, api_key: provider[:api_key])
            chat
          end
        end.to raise_error(RailsAgentConsole::InvalidResponseError, /no content/)
      end

      it "turns a failing status into a ProviderError naming the provider" do
        expect do
          serve({ error: { message: "nope" } }, status: 500) do |url|
            configure(name, url, api_key: provider[:api_key])
            chat
          end
        end.to raise_error(RailsAgentConsole::ProviderError, /#{provider[:label]} returned 500/)
      end

      it "reports an unreachable endpoint" do
        configure(name, dead_url, api_key: provider[:api_key])

        expect { chat }.to raise_error(RailsAgentConsole::ProviderError, /Could not reach #{provider[:label]}/)
      end

      next if name == :ollama

      it "refuses to call out without an API key" do
        configure(name, nil, api_key: nil)

        expect { chat }.to raise_error(RailsAgentConsole::ConfigurationError, /Missing API key/)
      end
    end
  end

  describe "listing models" do
    it "lists what an OpenAI-compatible endpoint serves, newest first" do
      exchanges, names = serve_in_turn(
        [[{ data: [{ id: "old-model", created: 1 }, { id: "new-model", created: 9 }] }]]
      ) do |url|
        configure(:openai, url, api_key: "sk-test")
        RailsAgentConsole::Providers::OpenAI.new(RailsAgentConsole.configuration).models
      end

      expect(names).to eq(%w[new-model old-model])
      expect(exchanges.first.path).to eq("/models")
    end

    it "lists the models Ollama has installed" do
      _, names = serve_in_turn([[{ models: [{ name: "qwen2.5-coder:7b" }] }]]) do |url|
        configure(:ollama, url, api_key: nil)
        RailsAgentConsole::Providers::Ollama.new(RailsAgentConsole.configuration).models
      end

      expect(names).to eq(["qwen2.5-coder:7b"])
    end

    it "lists nothing when the endpoint refuses" do
      _, names = serve_in_turn([[{ error: "nope" }, 401]]) do |url|
        configure(:anthropic, url, api_key: "sk-test")
        RailsAgentConsole::Providers::Anthropic.new(RailsAgentConsole.configuration).models
      end

      expect(names).to eq([])
    end
  end

  describe "an Ollama model that is not installed" do
    let(:missing) { [{ error: "model 'llama3.1' not found" }, 404] }

    it "answers with an installed model and says which" do
      exchanges, answer = serve_in_turn(
        [missing, [{ models: [{ name: "mistral:7b" }, { name: "qwen2.5-coder:7b" }] }],
         [{ message: { content: "answer text" } }]]
      ) do |url|
        configure(:ollama, url, api_key: nil, model: "llama3.1")
        chat
      end

      expect(answer).to eq("answer text")
      expect(exchanges.map(&:path)).to eq(["/api/chat", "/api/tags", "/api/chat"])
      expect(exchanges.last.body["model"]).to eq("qwen2.5-coder:7b")
      expect(printed).to include("llama3.1 is not installed in Ollama, so this uses qwen2.5-coder:7b",
                                 'ai_model "ollama/qwen2.5-coder:7b"')
    end

    it "points a hosted model at its own provider instead of ollama pull" do
      serve_in_turn(
        [[{ error: "model 'gpt-4o' not found" }, 404], [{ models: [{ name: "qwen2.5-coder:7b" }] }],
         [{ message: { content: "answer text" } }]]
      ) do |url|
        configure(:ollama, url, api_key: nil, model: "gpt-4o")
        chat
      end

      expect(printed).to include('ai_model "openai/gpt-4o"')
      expect(printed).not_to include("ollama pull gpt-4o")
    end

    it "says what to pull when nothing is installed" do
      expect do
        serve_in_turn([missing, [{ models: [] }]]) do |url|
          configure(:ollama, url, api_key: nil, model: "llama3.1")
          chat
        end
      end.to raise_error(RailsAgentConsole::ProviderError, /ollama pull qwen2.5-coder:7b/)
    end
  end

  describe "HTTP error bodies" do
    [
      [400, "Invalid request"],
      [401, "Incorrect API key provided"],
      [403, "Country not supported"],
      [429, "Rate limit reached"],
      [500, "Internal server error"],
      [503, "Service unavailable"]
    ].each do |status, message|
      it "surfaces #{status} with the provider message" do
        expect do
          serve({ error: { message: message } }, status: status) do |url|
            configure(:openai, url, api_key: "sk-openai")
            chat
          end
        end.to raise_error(RailsAgentConsole::ProviderError, /#{status}.*#{message}/)
      end
    end

    it "handles an error body that is a bare string" do
      expect do
        serve({ error: "boom" }, status: 502) do |url|
          configure(:openai, url, api_key: "sk-openai")
          chat
        end
      end.to raise_error(RailsAgentConsole::ProviderError, /boom/)
    end

    it "handles a non-JSON body" do
      expect do
        serve("<html>gateway timeout</html>", raw: true) do |url|
          configure(:openai, url, api_key: "sk-openai")
          chat
        end
      end.to raise_error(RailsAgentConsole::ProviderError, /non-JSON response/)
    end

    it "handles a non-JSON error body" do
      expect do
        serve("<html>bad gateway</html>", status: 502, raw: true) do |url|
          configure(:openai, url, api_key: "sk-openai")
          chat
        end
      end.to raise_error(RailsAgentConsole::ProviderError, /502/)
    end
  end

  describe "a custom client" do
    it "wins over every built-in provider" do
      RailsAgentConsole.configure do |config|
        config.provider = :anthropic
        config.client = ->(system:, messages:) { "#{system}|#{messages.size}" }
      end

      expect(described_class.build).to be_a(RailsAgentConsole::Providers::Callable)
      expect(chat).to eq("schema here|1")
    end

    it "reports an empty answer" do
      RailsAgentConsole.configuration.client = ->(**_call) { "" }

      expect { chat }.to raise_error(RailsAgentConsole::InvalidResponseError, /returned nothing/)
    end

    it "accepts anything callable" do
      RailsAgentConsole.configuration.client = proc { |system:, messages:| "#{system} #{messages.size}" }

      expect(chat).to eq("schema here 1")
    end
  end

  it "rejects an unknown provider" do
    RailsAgentConsole.configuration.provider = :hal9000

    expect { described_class.build }.to raise_error(RailsAgentConsole::ConfigurationError, /hal9000/)
  end
end
