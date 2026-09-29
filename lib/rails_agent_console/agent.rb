# frozen_string_literal: true

module RailsAgentConsole
  class Agent
    attr_reader :config, :ui, :history

    def initialize(config = RailsAgentConsole.configuration, ui: nil, history: nil)
      @config = config
      @ui = ui || UI.new(config)
      @history = history || History.new
    end

    def run(prompt, write: config.write_mode?)
      return usage if prompt.to_s.strip.empty?

      ui.heading "Inspecting application..."
      proposal = propose(prompt, write: write)
      return decline(proposal, write: write) if proposal.empty?

      present(proposal)

      return refuse_or_repair(prompt, proposal, write: write) unless proposal.safe?
      return unless confirmed?(proposal)

      execute(prompt, proposal, write: write)
    rescue ConfigurationError, ProviderError, InvalidResponseError => e
      ui.failure e.message
      nil
    end

    def ask(question)
      return usage if question.to_s.strip.empty?

      ensure_configured!
      ui.heading "Thinking..."
      answer = provider.chat(
        system: Prompt.explain_system(question),
        messages: [{ role: "user", content: Prompt::FollowUp.for_ask(question.to_s, history) }]
      )
      ui.blank
      ui.say answer.strip
      ui.blank
      nil
    rescue ConfigurationError, ProviderError, InvalidResponseError => e
      ui.failure e.message
      nil
    end

    def explain(code, question: nil)
      source = code.is_a?(String) ? code : safe_inspect(code)
      return usage if source.to_s.strip.empty?

      ask(Prompt.explain_code_user(source, question))
    end

    def propose(prompt, write: config.write_mode?, focus: prompt)
      ensure_configured!
      request = Prompt::Dates.annotate(prompt.to_s)
      request = Prompt::FollowUp.annotate(request, history.last&.code) if prompt.equal?(focus)
      raw = provider.chat(
        system: Prompt.query_system(focus, write_mode: write),
        messages: history.messages + [{ role: "user", content: request }]
      )
      Proposal.parse(raw, write_mode: write)
    end

    def provider
      @provider ||= Providers.build(config)
    end

    def reset_provider!
      @provider = nil
      self
    end

    def reset!
      history.clear
      Executor.reset!
      @provider = nil
      self
    end

    private

    def ensure_configured!
      return config.validate! if config.api_key?

      Setup.run(ui: ui) if Setup.interactive?(config)
      config.validate!
    end

    def present(proposal)
      narrate(proposal.models.first(3))
      ui.say ui.bold(proposal.writes? ? "Proposed command:" : "Proposed query:")
      ui.blank
      ui.code proposal.code
      ui.blank
      present_notes(proposal)
    end

    def present_notes(proposal)
      ui.note proposal.explanation if proposal.explanation
      proposal.assumptions.each { |assumption| ui.note "- #{assumption}" }
      proposal.corrections.each { |correction| ui.note "Corrected: #{correction}" }
    end

    def narrate(models)
      ui.tree(Schema.tree(models)) if models.any?
      ui.blank
    end

    def decline(proposal, write:)
      ui.blank
      ui.warn "No query to run."
      ui.note(proposal.explanation || retry_hint(proposal, write: write))
      ui.blank
      nil
    end

    def refuse(proposal, write:)
      ui.blank
      ui.warn "Refusing to run this code."
      proposal.violations.each { |violation| ui.say "  - #{violation}" }
      ui.blank
      ui.note retry_hint(proposal, write: write)
      nil
    end

    def retry_hint(proposal, write:)
      if proposal.writes? && !write
        "Read-only mode is on. Use `ai!` for a single write, or set " \
          "RailsAgentConsole.config.write_mode = true."
      else
        "Rephrase the request, or allow the call with " \
          "RailsAgentConsole.config.extra_allowed_methods << #{unknown_call(proposal).inspect}."
      end
    end

    def unknown_call(proposal)
      proposal.validation.unknown.first || "method_name"
    end

    def confirmed?(proposal)
      return true if config.auto_confirm?
      return destructive_confirmed?(proposal) if proposal.destructive?

      report_preflight(proposal)
      ui.blank
      ui.yes?("Execute?")
    end

    def report_preflight(proposal)
      count = Executor.preflight_count(proposal.code)
      return if count.nil?

      ui.blank
      ui.say "Found #{count} #{count == 1 ? "record" : "records"}."
    end

    def destructive_confirmed?(proposal)
      estimate = Executor.impact_estimate(proposal.code)
      ui.blank
      ui.warn "DESTRUCTIVE OPERATION"
      ui.say "  This will change approximately #{estimate} records." if estimate
      ui.say "  Affected calls: #{proposal.validation.writes.join(", ")}"
      ui.blank
      word = config.destructive_confirmation_word
      answer = ui.ask("Type \"#{word}\" to continue:")
      return true if answer.to_s.strip == word

      ui.note "Cancelled."
      false
    end

    def execute(prompt, proposal, write:, attempts_left: config.max_repair_attempts.to_i, attempted: [])
      outcome = Executor.run(proposal.code)
      ui.blank
      summary = outcome.ok? ? report_success(outcome) : report_failure(outcome)
      remember(prompt, proposal, summary)

      if !outcome.ok? && attempts_left.positive?
        tried = attempted + [attempt(proposal, failure_reason(outcome, proposal.code))]
        repair(prompt, tried, write: write, attempts_left: attempts_left)
      else
        ui.blank
        outcome.value
      end
    end

    def attempt(proposal, reason)
      { code: proposal.code, reason: reason }
    end

    def failure_reason(outcome, code)
      error = outcome.error
      message = "#{error.class}: #{error.message.to_s.lines.first.to_s.strip}"
      hint = Diagnosis.hint(code, error.message)
      hint ? "#{message}\n#{hint}" : message
    end

    def refuse_or_repair(prompt, proposal, write:, attempted: [], attempts_left: config.max_repair_attempts.to_i)
      refuse(proposal, write: write)
      return unless attempts_left.positive? && proposal.validation.repairable?

      tried = attempted + [attempt(proposal, refusal_reason(proposal))]
      repair(prompt, tried, write: write, attempts_left: attempts_left)
    end

    def refusal_reason(proposal)
      "The code was refused before it ran: #{proposal.violations.join("; ")}"
    end

    def repair(prompt, attempted, write:, attempts_left:)
      ui.blank
      ui.heading "Fixing the query..."
      fixed = propose(Prompt.repair_user(prompt, attempted), write: write, focus: prompt)
      return unrepairable(fixed, attempted) if fixed.empty? || tried?(fixed, attempted)

      present(fixed)

      if fixed.safe?
        return unless confirmed?(fixed)

        execute(prompt, fixed, write: write, attempts_left: attempts_left - 1, attempted: attempted)
      else
        refuse_or_repair(prompt, fixed, write: write, attempted: attempted, attempts_left: attempts_left - 1)
      end
    end

    def tried?(proposal, attempted)
      attempted.any? { |earlier| earlier[:code] == proposal.code }
    end

    def unrepairable(fixed, attempted)
      ui.blank
      ui.note(if tried?(fixed, attempted)
                "The model came back with a query it had already tried."
              else
                fixed.explanation || "No corrected query to run."
              end)
      ui.blank
      nil
    end

    def report_success(outcome)
      summary = Executor.describe(outcome.value)
      ui.success "#{summary} in #{format("%.0f", outcome.duration * 1000)}ms"
      ui.note outcome.note if outcome.note
      summary
    end

    def report_failure(outcome)
      ui.failure "#{outcome.error.class}: #{outcome.error.message.to_s.lines.first}"
      "failed: #{outcome.error.class}"
    end

    def remember(prompt, proposal, summary)
      history.add(prompt: prompt, code: proposal.code,
                  explanation: proposal.explanation, outcome: summary)
    end

    def usage
      ui.note 'Usage: ai "how many users signed up this month?"'
      nil
    end

    def safe_inspect(value)
      if Executor.relation?(value)
        "An ActiveRecord::Relation on #{value.klass.name}, generating:\n#{value.to_sql}"
      else
        value.inspect
      end
    rescue StandardError
      value.to_s
    end
  end
end
