# frozen_string_literal: true

module RailsAgentConsole
  class Configuration
    PROVIDERS = %i[openai anthropic gemini ollama].freeze

    DEFAULT_MODELS = {
      openai: "gpt-4o-mini",
      anthropic: "claude-3-5-sonnet-latest",
      gemini: "gemini-2.0-flash",
      ollama: "qwen2.5-coder:7b"
    }.freeze

    ENV_KEYS = {
      openai: "OPENAI_API_KEY",
      anthropic: "ANTHROPIC_API_KEY",
      gemini: "GEMINI_API_KEY",
      ollama: "OLLAMA_API_KEY"
    }.freeze

    MODEL_OWNERS = {
      openai: /\A(gpt-(\d|4o)|chatgpt-|o\d+(-|\z))/i,
      anthropic: /\Aclaude-/i,
      gemini: /\Agemini-/i
    }.freeze

    def self.provider_for(model)
      name = model.to_s.strip
      return if name.include?(":")

      MODEL_OWNERS.find { |_, pattern| pattern.match?(name) }&.first
    end

    attr_writer :model, :api_key, :api_base
    attr_accessor :temperature, :request_timeout,
                  :write_mode, :auto_confirm, :destructive_confirmation_word,
                  :extra_allowed_methods, :extra_allowed_constants, :execution_timeout, :preflight_count,
                  :max_models, :max_focused_models, :include_internal_models, :excluded_models, :extra_context,
                  :max_history, :max_repair_attempts,
                  :color, :banner, :setup_on_boot, :input, :output, :inspect_limit, :console_helpers,
                  :client

    def initialize
      @api_base = nil
      @temperature = 0.0
      @request_timeout = 60

      @write_mode = false
      @auto_confirm = false
      @destructive_confirmation_word = "execute"
      @extra_allowed_methods = []
      @extra_allowed_constants = []
      @execution_timeout = 30
      @preflight_count = true

      @max_models = 60
      @max_focused_models = 8
      @include_internal_models = false
      @excluded_models = []
      @extra_context = nil

      @max_history = 6
      @max_repair_attempts = 3

      @color = nil # nil means "decide from the output stream"
      @banner = true
      @setup_on_boot = true
      @input = nil
      @output = nil
      @inspect_limit = 20
      @console_helpers = %i[ai ai! ask explain run ai_history ai_reset ai_schema ai_model]

      @client = nil
    end

    def provider
      @provider ||= detected_provider
    end

    def provider=(name)
      @provider = name&.to_sym
      @api_key = nil
      @model = nil
    end

    def model
      @model ||= Credentials.read.dig(provider.to_s, "model") ||
                 DEFAULT_MODELS[provider] ||
                 DEFAULT_MODELS[:openai]
    end

    def api_key
      @api_key ||= blank_to_nil(ENV.fetch(ENV_KEYS.fetch(provider, ""), nil)) ||
                   blank_to_nil(Credentials.read.dig(provider.to_s, "api_key"))
    end

    def api_base
      @api_base || blank_to_nil(Credentials.read.dig(provider.to_s, "base_url"))
    end

    def snapshot
      { provider: provider, model: @model, api_key: @api_key, api_base: @api_base }
    end

    def restore(state)
      @provider, @model, @api_key, @api_base = state.values_at(:provider, :model, :api_key, :api_base)
      self
    end

    def api_key?
      !api_key.nil? || provider == :ollama || !client.nil?
    end

    def key_for?(name)
      return true if name.to_sym == :ollama

      !blank_to_nil(ENV.fetch(ENV_KEYS.fetch(name.to_sym, ""), nil)).nil? ||
        !blank_to_nil(Credentials.read.dig(name.to_s, "api_key")).nil?
    end

    def write_mode?
      !!@write_mode
    end

    def auto_confirm?
      !!@auto_confirm
    end

    def color?
      return @color unless @color.nil?

      out = output || $stdout
      out.respond_to?(:tty?) && out.tty?
    end

    def in
      @input || $stdin
    end

    def out
      @output || $stdout
    end

    def validate!
      unless PROVIDERS.include?(provider)
        raise ConfigurationError, "Unknown provider #{provider.inspect}. Supported: #{PROVIDERS.join(", ")}."
      end

      return true if api_key?

      raise ConfigurationError,
            "No API key for #{provider}. Set #{ENV_KEYS[provider]}, run `rails-agent configure`, " \
            "or set RailsAgentConsole.config.api_key."
    end

    private

    def blank_to_nil(value)
      value.to_s unless value.to_s.strip.empty?
    end

    def detected_provider
      from_file = Credentials.read["default_provider"]
      return from_file.to_sym if from_file && PROVIDERS.include?(from_file.to_sym)

      detected = PROVIDERS.find { |name| !blank_to_nil(ENV.fetch(ENV_KEYS[name], nil)).nil? }
      detected || :openai
    end
  end
end
