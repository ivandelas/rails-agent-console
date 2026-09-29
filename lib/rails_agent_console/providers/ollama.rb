# frozen_string_literal: true

module RailsAgentConsole
  module Providers
    class Ollama < Base
      DEFAULT_BASE = "http://localhost:11434"
      CONTEXT_TOKENS = 8192
      ANSWER_TOKENS = 1024
      MISSING_MODEL = /model ['"]?([^'"]+?)['"]? not found/
      RECOMMENDED = "qwen2.5-coder:7b"

      def name
        "Ollama"
      end

      def chat(system:, messages:)
        super
      rescue ProviderError => e
        missing = e.message[MISSING_MODEL, 1]
        raise if missing.nil?

        switch_from(missing)
        super
      end

      def installed_models
        Array(get("#{base_url(DEFAULT_BASE)}/api/tags")&.dig("models")).filter_map { |model| model["name"] }
      end

      def models
        installed_models
      end

      private

      def switch_from(missing)
        installed = installed_models
        raise ProviderError, nothing_installed(missing) if installed.empty?

        config.model = pick(installed)
        UI.new(config).warn("#{missing} is not installed in Ollama, so this uses #{config.model}. " \
                            "Keep it with ai_model \"ollama/#{config.model}\", #{way_to(missing)}.")
      end

      def way_to(missing)
        owner = Configuration.provider_for(missing)
        return "or install the other with `ollama pull #{missing}`" if owner.nil?

        "or use #{missing} where it runs with ai_model \"#{owner}/#{missing}\""
      end

      def pick(installed)
        installed.find { |model| model.start_with?(RECOMMENDED) } ||
          installed.find { |model| model.include?("coder") } ||
          installed.first
      end

      def nothing_installed(missing)
        "Ollama has no models installed, so #{missing} cannot answer. " \
          "Install one with `ollama pull #{RECOMMENDED}` and ask again."
      end

      def endpoint
        "#{base_url(DEFAULT_BASE)}/api/chat"
      end

      def payload(system:, messages:)
        {
          model: model,
          stream: false,
          options: { temperature: config.temperature, num_ctx: CONTEXT_TOKENS, num_predict: ANSWER_TOKENS },
          messages: [{ role: "system", content: system }] + messages
        }
      end

      def extract(response)
        content = response.dig("message", "content").to_s
        raise InvalidResponseError, "Ollama returned no content" if content.strip.empty?

        content
      end
    end
  end
end
