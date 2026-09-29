# frozen_string_literal: true

module RailsAgentConsole
  module ConsoleSession
    class << self
      def start(config: RailsAgentConsole.configuration, ui: UI.new(config))
        banner(ui, config) if config.banner
        return unless config.setup_on_boot && Setup.needed?(config)

        if Setup.interactive?(config)
          Setup.run(config: config, ui: ui)
        else
          ui.note "rails_agent_console: no API key found. Run `rails-agent configure` to set one up."
        end
      rescue Interrupt
        ui.blank
        ui.note "Skipped. Run `rails-agent configure` later."
      end

      private

      def banner(ui, config)
        ui.blank
        ui.heading "Rails Agent Console #{VERSION}"
        details = ["#{config.provider}/#{config.model}"]
        details << (config.write_mode? ? "WRITE MODE" : "read-only")
        ui.note "  #{details.join("  |  ")}"
        ui.note '  ai "how many users signed up this month?"   ask "..."   explain User.all'
        ui.note "  ai_model  to switch model or provider#{elsewhere(config)}"
        ui.blank
      end

      def elsewhere(config)
        others = (Configuration::PROVIDERS - [config.provider]).select do |name|
          name == :ollama || config.key_for?(name)
        end
        others.empty? ? "" : " (#{others.join(", ")} also on hand)"
      end
    end
  end
end
