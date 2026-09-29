# frozen_string_literal: true

module RailsAgentConsole
  # Usage:
  #   ai_model                             # what is in use, then a guided change
  #   ai_model "gpt-4o"                    # the provider follows from the name
  #   ai_model "ollama/qwen2.5-coder:7b"   # a provider, and its model
  module ModelPicker
    class << self
      def run(target = nil, config: RailsAgentConsole.configuration, ui: UI.new(config))
        return switch(target, config: config, ui: ui) unless target.nil?

        report(config, ui)
        return unless Setup.interactive?(config)
        return unless ui.yes?("Change provider, base URL or model?", default: false)

        Wizard.run(config: config, ui: ui)
        nil
      end

      private

      def switch(target, config:, ui:)
        choice = parse(target, config)
        return unknown(target, ui) if choice.nil?

        before = config.snapshot
        apply(choice, config)
        unless ollama_has_model?(config, ui)
          config.restore(before)
          return
        end

        typed = config.api_key? ? nil : read_key(config, ui)
        return refuse_without_key(before, config, ui) unless config.api_key?

        RailsAgentConsole.agent.reset_provider!
        ui.success "Now using #{label(config)}."
        remember(config, ui, typed)
        nil
      end

      def apply(choice, config)
        if choice[:provider] != config.provider
          config.provider = choice[:provider]
          config.api_base = nil
        end
        config.model = choice[:model] || stored_model(config.provider) ||
                       Configuration::DEFAULT_MODELS[config.provider]
      end

      def parse(target, config)
        text = target.to_s.strip
        return if text.empty?

        provider, model = text.split("/", 2)
        return { provider: provider.to_sym, model: model } if known?(provider) && !model.to_s.empty?
        return { provider: provider.to_sym, model: nil } if known?(provider) && model.nil?
        return if text.include?("/")

        { provider: Configuration.provider_for(text) || config.provider, model: text }
      end

      def known?(name)
        Configuration::PROVIDERS.include?(name.to_s.to_sym)
      end

      def unknown(target, ui)
        ui.failure "#{target.inspect} names no provider. Known: #{Configuration::PROVIDERS.join(", ")}."
        nil
      end

      def ollama_has_model?(config, ui)
        return true unless config.provider == :ollama

        installed = Providers::Ollama.new(config).installed_models
        if installed.empty?
          ui.warn "Ollama did not list any models on #{config.api_base || Providers::Ollama::DEFAULT_BASE}. " \
                  "Start it with `ollama serve`, and get a model with `ollama pull #{config.model}`."
          return true
        end
        return true if installed.include?(config.model) || installed.include?("#{config.model}:latest")

        ui.failure "#{config.model} is not installed in Ollama. Installed: #{installed.join(", ")}."
        ui.note "  Get it with `ollama pull #{config.model}`, or pick one of those with ai_model \"ollama/NAME\"."
        false
      end

      def read_key(config, ui)
        return unless Setup.interactive?(config)

        env = Configuration::ENV_KEYS[config.provider]
        ui.note "  #{Setup::PROVIDER_LABELS[config.provider]} needs an API key. It is read from #{env}; " \
                "or type it here, it will not be shown."
        key = ui.secret("#{config.provider} API key:")
        return if key.empty?

        config.api_key = key
      end

      def refuse_without_key(before, config, ui)
        provider = config.provider
        config.restore(before)
        how = Setup.interactive?(config) ? "none was typed" : "run ai_model in a terminal to type one"
        ui.failure "No key for #{provider} (set #{Configuration::ENV_KEYS[provider]}, or #{how}), " \
                   "so this stays on #{label(config)}."
        nil
      end

      def remember(config, ui, typed_key)
        return unless Setup.interactive?(config)
        return unless ui.yes?("Make #{label(config)} the default in #{Credentials.path}?", default: false)

        Credentials.store(provider: config.provider, api_key: typed_key, model: config.model)
        ui.success "Saved."
      rescue StandardError => e
        ui.failure "Could not write #{Credentials.path}: #{e.message}"
      end

      def stored_model(provider)
        Credentials.read.dig(provider.to_s, "model")
      end

      def report(config, ui)
        ui.blank
        ui.say "#{ui.bold(label(config))}  |  #{where(config.provider, config)}"
        ui.blank
        Configuration::PROVIDERS.each { |name| ui.say "  #{row(name, config)}" }
        ui.blank
        ui.note '  ai_model "gpt-4o"                   any model; the provider follows from the name'
        ui.note '  ai_model "ollama/qwen2.5-coder:7b"  a provider, and its model'
        ui.blank
      end

      def row(name, config)
        current = name == config.provider
        model = current ? config.model : stored_model(name) || Configuration::DEFAULT_MODELS[name]
        "#{current ? "*" : " "} #{name.to_s.ljust(10)} #{model.to_s.ljust(26)} #{where(name, config)}"
      end

      def where(name, config)
        base = name == config.provider ? config.api_base : Credentials.read.dig(name.to_s, "base_url")
        note = key_note(name, config, base)
        base && name != :ollama ? "#{note}, via #{base}" : note
      end

      def key_note(name, config, base)
        return "runs locally, needs Ollama on #{base || Providers::Ollama::DEFAULT_BASE}" if name == :ollama

        env = Configuration::ENV_KEYS[name]
        return "key from #{env}" unless ENV.fetch(env, "").strip.empty?
        return "key from #{Credentials.path}" if stored_key?(name)

        config.client ? "unused: config.client answers instead" : "no key (set #{env})"
      end

      def stored_key?(name)
        !Credentials.read.dig(name.to_s, "api_key").to_s.strip.empty?
      end

      def label(config)
        "#{config.provider}/#{config.model}"
      end
    end
  end
end
