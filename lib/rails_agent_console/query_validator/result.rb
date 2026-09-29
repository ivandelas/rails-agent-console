# frozen_string_literal: true

module RailsAgentConsole
  class QueryValidator
    class Result
      attr_reader :code, :violations, :writes, :methods, :constants, :unknown, :unknown_constants

      def initialize(code:, violations:, writes:, methods:, constants:,
                     unknown: [], unknown_constants: [], blocked: false, syntax_error: false)
        @code = code
        @violations = violations.uniq
        @writes = writes.uniq
        @methods = methods.uniq
        @constants = constants.uniq
        @unknown = unknown.uniq
        @unknown_constants = unknown_constants.uniq
        @blocked = blocked
        @syntax_error = syntax_error
      end

      def valid?
        @violations.empty?
      end

      def blocked?
        @blocked
      end

      def syntax_error?
        @syntax_error
      end

      def repairable?
        !valid? && !blocked? && @writes.empty? &&
          (syntax_error? || @unknown.any? || @unknown_constants.any?)
      end

      def writes?
        @writes.any?
      end

      def destructive?
        @writes.any? { |name| Rules::DESTRUCTIVE.include?(name) }
      end

      def models
        @constants & Schema.model_names
      end

      def to_s
        valid? ? "valid" : "invalid: #{@violations.join("; ")}"
      end
    end
  end
end
