# frozen_string_literal: true

module RailsAgentConsole
  class Error < StandardError; end

  class ConfigurationError < Error; end

  class InvalidResponseError < Error; end

  class ProviderError < Error; end

  class UnsafeCodeError < Error
    attr_reader :violations

    def initialize(message, violations: [])
      super(message)
      @violations = violations
    end
  end
end
