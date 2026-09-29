# frozen_string_literal: true

module RailsAgentConsole
  module Providers
    class Gemini < Base
      DEFAULT_BASE = "https://generativelanguage.googleapis.com/v1beta"

      def name
        "Gemini"
      end

      def models
        listed = Array(get("#{base_url(DEFAULT_BASE)}/models?pageSize=200&key=#{api_key!}")&.dig("models"))
        listed.select { |entry| Array(entry["supportedGenerationMethods"]).include?("generateContent") }
              .filter_map { |entry| entry["name"].to_s.delete_prefix("models/") }
      rescue ConfigurationError
        []
      end

      private

      def endpoint
        "#{base_url(DEFAULT_BASE)}/models/#{model}:generateContent?key=#{api_key!}"
      end

      def payload(system:, messages:)
        {
          system_instruction: { parts: [{ text: system }] },
          generationConfig: { temperature: config.temperature },
          contents: messages.map do |message|
            { role: message[:role] == "assistant" ? "model" : "user", parts: [{ text: message[:content] }] }
          end
        }
      end

      def extract(response)
        parts = response.dig("candidates", 0, "content", "parts")
        content = Array(parts).filter_map { |part| part["text"] }.join.strip
        raise InvalidResponseError, "Gemini returned no content" if content.empty?

        content
      end
    end
  end
end
