# frozen_string_literal: true

# rails_agent_console is only active inside `rails console`.
# API keys are read from the environment or ~/.rails_agent_console/config,
# so nothing secret belongs in this file.
RailsAgentConsole.configure do |config|
  # config.provider = :openai          # :openai, :anthropic, :gemini, :ollama
  # config.model    = "gpt-4o-mini"

  # Safety. Leave write_mode off; use `ai!` for a one-off write instead.
  # config.write_mode = false
  # config.extra_allowed_methods = %w[to_csv]

  # Schema context sent to the model.
  # config.excluded_models = %w[AuditLog]
  # config.max_focused_models = 8
  # config.extra_context = "Revenue always lives on Payment#amount_cents."

  # Console helpers to install (drop :run if it collides with your own helper).
  # config.console_helpers = %i[ai ai! ask explain run]
end
