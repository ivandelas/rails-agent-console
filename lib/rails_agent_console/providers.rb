# frozen_string_literal: true

require_relative "providers/base"
require_relative "providers/openai"
require_relative "providers/anthropic"
require_relative "providers/gemini"
require_relative "providers/ollama"
require_relative "providers/callable"

module RailsAgentConsole
  module Providers
    REGISTRY = {
      openai: OpenAI,
      anthropic: Anthropic,
      gemini: Gemini,
      ollama: Ollama
    }.freeze

    def self.build(config = RailsAgentConsole.configuration)
      return Callable.new(config) if config.client

      klass = REGISTRY[config.provider]
      raise ConfigurationError, "Unknown provider #{config.provider.inspect}" unless klass

      klass.new(config)
    end
  end
end
