# frozen_string_literal: true

module RailsAgentConsole
  class Wizard
    PLACES = [
      [:local, "On this machine, with Ollama. Nothing leaves your laptop, no key needed."],
      [:hosted, "A hosted API: OpenAI, Anthropic or Gemini."],
      [:custom, "My own OpenAI-compatible endpoint: OpenRouter, LM Studio, vLLM, a company gateway."]
    ].freeze
    HOSTED = %i[openai anthropic gemini].freeze
    LISTED = 15

    def self.run(config: RailsAgentConsole.configuration, ui: UI.new(config))
      new(config, ui).run
    end

    def initialize(config, ui)
      @config = config
      @ui = ui
      @before = config.snapshot
      @typed_key = nil
      @step = 0
    end

    def run
      place = choose_place
      provider = place == :hosted ? choose_hosted : { local: :ollama, custom: :openai }[place]
      return abandon("Unknown choice.") if provider.nil?

      use(provider)
      choose_base_url(place)
      return abandon("No key entered, nothing changed.") unless key_ready?

      @config.model = choose_model
      return abandon("Nothing changed.") unless answers?

      RailsAgentConsole.agent.reset_provider!
      @ui.success "Now using #{label}."
      offer_to_save
      true
    end

    private

    def step(title)
      @step += 1
      @ui.blank
      @ui.say @ui.bold("#{@step}. #{title}")
    end

    def choose_place
      step "Where should the model run?"
      current = current_place
      PLACES.each_with_index do |(name, text), index|
        @ui.say "  #{index + 1}. #{text}#{@ui.dim("  (now)") if name == current}"
      end
      answer = @ui.ask(">", default: (PLACES.index { |name, _| name == current } + 1).to_s)
      PLACES.dig(answer.to_i - 1, 0) || PLACES.find { |name, _| name.to_s == answer.downcase }&.first
    end

    def current_place
      return :local if @config.provider == :ollama
      return :custom if @config.provider == :openai && @config.api_base && @config.api_base != default_base(:openai)

      :hosted
    end

    def choose_hosted
      step "Which provider?"
      HOSTED.each_with_index do |name, index|
        @ui.say "  #{index + 1}. #{Setup::PROVIDER_LABELS[name].ljust(10)} #{@ui.dim(key_source(name))}"
      end
      default = HOSTED.index(@config.provider) || 0
      answer = @ui.ask(">", default: (default + 1).to_s)
      return HOSTED[answer.to_i - 1] if answer.to_i.between?(1, HOSTED.size)

      HOSTED.find { |name| name.to_s == answer.downcase }
    end

    def use(provider)
      same = provider == @before[:provider]
      @config.provider = provider
      @config.api_key = @before[:api_key] if same && @before[:api_key]
    end

    def choose_base_url(place)
      step "Base URL"
      stored = Credentials.read.dig(@config.provider.to_s, "base_url")
      default = place == :custom ? stored : stored || default_base(@config.provider)
      @ui.note "  Where the requests go. Enter keeps it." unless default.to_s.empty?
      @ui.note "  The part before /chat/completions, e.g. https://openrouter.ai/api/v1" if place == :custom
      answer = @ui.ask(default.to_s.empty? ? "Base URL:" : "Base URL [#{default}]:", default: default).to_s
      @config.api_base = answer.chomp("/") == default_base(@config.provider) ? nil : answer.chomp("/")
      check_ollama if @config.provider == :ollama
    end

    def check_ollama
      found = provider.models
      if found.any?
        return @ui.success "Ollama answers on #{base}, #{found.size} #{found.one? ? "model" : "models"} installed."
      end

      @ui.warn "Nothing answered on #{base}. Start Ollama with `ollama serve`, then carry on."
    end

    def key_ready?
      return true if @config.provider == :ollama

      step "API key"
      source = existing_key
      @ui.success "Using #{source}." if source
      source ? true : typed_key?
    end

    def existing_key
      env = Configuration::ENV_KEYS[@config.provider]
      return env_key_choice(env) if env_key? && @config.api_base.nil?

      "the key already set for #{@config.provider}" if @config.api_key && !replace_key?
    end

    def env_key_choice(env)
      @ui.say "  Found a key in #{env}."
      return "the key from #{env}" if @ui.yes?("Use it?", default: true)

      @ui.note "  The key you type is used from now on in this console. #{env} is still set, so a new " \
               "session goes back to it unless you unset it or change it where it is defined (.env, shell profile)."
      nil
    end

    def replace_key?
      @ui.yes?("A key is already set for #{@config.provider}. Type a different one?", default: false)
    end

    def typed_key?
      skip = env_key? ? "" : " Set #{Configuration::ENV_KEYS[@config.provider]} to skip this step."
      @ui.note "  Not echoed, and never written into the application.#{skip}"
      key = @ui.secret("#{Setup::PROVIDER_LABELS[@config.provider]} API key:")
      return false if key.empty?

      @typed_key = @config.api_key = key
      true
    end

    def choose_model
      step "Model"
      found = provider.models
      default = default_model(found)
      return ask_any_model(default) if found.empty?

      shown = (([default] & found) + (found - [default])).first(LISTED)
      shown.each_with_index { |name, index| @ui.say "  #{index + 1}. #{name}" }
      @ui.note "  ...and #{found.size - LISTED} more; type any name." if found.size > LISTED
      numbered(shown, @ui.ask("Number or name [#{default}]:", default: default))
    end

    def numbered(shown, answer)
      answer.match?(/\A\d+\z/) && answer.to_i.between?(1, shown.size) ? shown[answer.to_i - 1] : answer
    end

    def ask_any_model(default)
      @ui.note "  Could not list the models here, so type the name the API expects."
      @ui.note "  For Ollama, get one first with `ollama pull #{default}`." if @config.provider == :ollama
      @ui.ask("Model [#{default}]:", default: default)
    end

    def default_model(found)
      current = @before[:provider] == @config.provider ? @before[:model] : nil
      preferred = [current, Credentials.read.dig(@config.provider.to_s, "model"),
                   Configuration::DEFAULT_MODELS[@config.provider]].compact
      return preferred.first if found.empty?

      preferred.find { |name| found.include?(name) } ||
        found.find { |name| name.start_with?(Providers::Ollama::RECOMMENDED) } ||
        found.find { |name| name.include?("coder") } || found.first
    end

    def answers?
      @ui.blank
      @ui.say "Checking #{label}..."
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      provider.chat(system: "You are a health check. Answer with the single word: ok",
                    messages: [{ role: "user", content: "ping" }])
      @ui.success format("It answered in %.1fs.", Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      true
    rescue Error => e
      @ui.failure e.message
      @ui.yes?("Keep #{label} anyway?", default: false)
    end

    def offer_to_save
      return unless @ui.yes?("Make it the default in #{Credentials.path}?", default: true)

      path = Credentials.store(provider: @config.provider, api_key: @typed_key, model: @config.model,
                               base_url: @config.api_base.to_s)
      @ui.success "Saved to #{path} (chmod 600)."
    rescue StandardError => e
      @ui.failure "Could not write #{Credentials.path}: #{e.message}"
    end

    def abandon(message)
      @config.restore(@before)
      @ui.failure(@config.api_key? ? "#{message} Still on #{label}." : message)
      nil
    end

    def provider
      Providers::REGISTRY.fetch(@config.provider).new(@config)
    end

    def default_base(name)
      Providers::REGISTRY.fetch(name)::DEFAULT_BASE
    end

    def base
      @config.api_base || default_base(@config.provider)
    end

    def env_key?
      !ENV.fetch(Configuration::ENV_KEYS[@config.provider], "").strip.empty?
    end

    def key_source(name)
      env = Configuration::ENV_KEYS[name]
      return "key from #{env}" unless ENV.fetch(env, "").strip.empty?
      return "key stored in #{Credentials.path}" if Credentials.read.dig(name.to_s, "api_key").to_s.strip != ""

      "no key yet"
    end

    def label
      "#{@config.provider}/#{@config.model}"
    end
  end
end
