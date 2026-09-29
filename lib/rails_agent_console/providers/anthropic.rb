# frozen_string_literal: true

module RailsAgentConsole
  module Providers
    class Anthropic < Base
      DEFAULT_BASE = "https://api.anthropic.com/v1"
      API_VERSION = "2023-06-01"

      def name
        "Anthropic"
      end

      def models
        listed = get("#{base_url(DEFAULT_BASE)}/models?limit=100", headers)
        Array(listed&.dig("data")).filter_map { |entry| entry["id"] }
      rescue ConfigurationError
        []
      end

      private

      def endpoint
        "#{base_url(DEFAULT_BASE)}/messages"
      end

      def headers
        super.merge("x-api-key" => api_key!, "anthropic-version" => API_VERSION)
      end

      def payload(system:, messages:)
        {
          model: model,
          system: system,
          max_tokens: 1024,
          temperature: config.temperature,
          messages: messages
        }
      end

      def extract(response)
        content = Array(response["content"]).filter_map { |part| part["text"] }.join.strip
        raise InvalidResponseError, "Anthropic returned no content" if content.empty?

        content
      end
    end
  end
end
