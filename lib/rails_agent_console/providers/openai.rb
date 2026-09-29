# frozen_string_literal: true

module RailsAgentConsole
  module Providers
    class OpenAI < Base
      DEFAULT_BASE = "https://api.openai.com/v1"

      CHAT_MODEL = /\A(gpt-|chatgpt-|o\d)/
      NOT_CHAT = /audio|realtime|tts|transcribe|image|search|embedding|instruct|-\d{4}(-\d\d-\d\d)?\z/

      def name
        "OpenAI"
      end

      def models
        listed = Array(get("#{base_url(DEFAULT_BASE)}/models", headers)&.dig("data"))
        listed = listed.sort_by { |entry| -entry["created"].to_i }.filter_map { |entry| entry["id"] }
        return listed unless base_url(DEFAULT_BASE) == DEFAULT_BASE

        listed.grep(CHAT_MODEL).grep_v(NOT_CHAT)
      rescue ConfigurationError
        []
      end

      private

      def endpoint
        "#{base_url(DEFAULT_BASE)}/chat/completions"
      end

      def headers
        super.merge("Authorization" => "Bearer #{api_key!}")
      end

      def payload(system:, messages:)
        {
          model: model,
          temperature: config.temperature,
          messages: [{ role: "system", content: system }] + messages
        }
      end

      def extract(response)
        content = response.dig("choices", 0, "message", "content")
        raise InvalidResponseError, "OpenAI returned no content" if content.nil? || content.strip.empty?

        content
      end
    end
  end
end
