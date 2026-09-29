# frozen_string_literal: true

require "json"

module RailsAgentConsole
  class History
    Turn = Struct.new(:prompt, :code, :explanation, :outcome, keyword_init: true)

    def initialize(limit: nil)
      @limit = limit
      @turns = []
    end

    def limit
      @limit || RailsAgentConsole.configuration.max_history
    end

    def add(prompt:, code:, explanation: nil, outcome: nil)
      @turns << Turn.new(prompt: prompt, code: code, explanation: explanation, outcome: outcome)
      @turns.shift while @turns.size > limit
      self
    end

    def turns
      @turns.dup
    end

    def last
      @turns.last
    end

    def empty?
      @turns.empty?
    end

    def clear
      @turns.clear
      self
    end

    def messages
      @turns.flat_map do |turn|
        [
          { role: "user", content: turn.prompt },
          { role: "assistant", content: assistant_content(turn) }
        ]
      end
    end

    def to_s
      return "(no queries yet)" if empty?

      @turns.map.with_index(1) { |turn, i| "#{i}. #{turn.prompt}\n   #{turn.code}" }.join("\n")
    end

    private

    def assistant_content(turn)
      payload = { "code" => turn.code }
      payload["explanation"] = turn.explanation if turn.explanation
      payload["result"] = turn.outcome if turn.outcome
      JSON.generate(payload)
    end
  end
end
