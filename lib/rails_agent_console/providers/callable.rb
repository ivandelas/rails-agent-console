# frozen_string_literal: true

module RailsAgentConsole
  module Providers
    # Example:
    #   RailsAgentConsole.configure do |c|
    #     c.client = ->(system:, messages:) do
    #       RubyLLM.chat.with_instructions(system).ask(messages.last[:content]).content
    #     end
    #   end
    class Callable < Base
      def name
        "custom client"
      end

      def model
        config.model
      end

      def chat(system:, messages:)
        result = config.client.call(system: system, messages: messages)
        raise InvalidResponseError, "config.client returned nothing" if result.to_s.strip.empty?

        result.to_s
      end
    end
  end
end
