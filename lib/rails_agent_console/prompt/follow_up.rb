# frozen_string_literal: true

module RailsAgentConsole
  module Prompt
    module FollowUp
      BACK_REFERENCE = /\b(them|those|these|they|their|the same|ih|njih|njima|njihov\w*|tih|isto)\b/i
      EARLIER_QUERY = /\b(quer(y|ies)|that|this|last|previous|earlier|you gave|upit\w*|prethodn\w*|zadnj\w*)\b/i
      ASKED_ABOUT = 3
      TERMINALS = %w[count size length sum average minimum maximum pluck ids first last exists? any? to_a].freeze
      TERMINAL = /\.\s*(#{Regexp.union(TERMINALS).source})(?<args>\((?:[^()]|\g<args>)*\))?\s*\z/m

      module_function

      def annotate(prompt, previous_code)
        base = base_of(previous_code)
        return prompt if base.nil? || !prompt.match?(BACK_REFERENCE)

        "#{prompt}\n\nThis continues the previous query. Keep its conditions and build on: #{base}"
      end

      def for_ask(question, history)
        return question if history.empty?
        return question unless question.match?(BACK_REFERENCE) || question.match?(EARLIER_QUERY)

        recent = history.turns.last(ASKED_ABOUT).map { |turn| "- #{turn.prompt}\n  #{turn.code}" }
        "#{question}\n\nQueries run earlier in this console session, oldest first:\n#{recent.join("\n")}"
      end

      def base_of(code)
        base = code.to_s.strip
        return if base.empty?

        base = base.sub(TERMINAL, "") while base.match?(TERMINAL)
        base unless base.empty?
      end
    end
  end
end
