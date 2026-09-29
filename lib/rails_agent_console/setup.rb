# frozen_string_literal: true

module RailsAgentConsole
  module Setup
    PROVIDER_LABELS = {
      openai: "OpenAI",
      anthropic: "Anthropic",
      gemini: "Gemini",
      ollama: "Ollama"
    }.freeze

    class << self
      def interactive?(config = RailsAgentConsole.configuration)
        input = config.in
        input.respond_to?(:tty?) && input.tty?
      end

      def needed?(config = RailsAgentConsole.configuration)
        !config.api_key?
      end

      def run(config: RailsAgentConsole.configuration, ui: UI.new(config))
        ui.blank
        ui.heading "Rails Agent Console"
        ui.say "No AI provider configured yet. A few short questions; Enter takes the suggestion."
        return false unless Wizard.run(config: config, ui: ui)

        ui.success "Ready. Try: ai \"how many #{example_model.downcase} records do we have?\""
        ui.blank
        true
      end

      private

      def example_model
        Schema.model_names.first || "User"
      end
    end
  end
end
