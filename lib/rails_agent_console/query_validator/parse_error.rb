# frozen_string_literal: true

require "ripper"

module RailsAgentConsole
  class QueryValidator
    class ParseError < Ripper
      def self.message_for(code)
        parser = new(code)
        parser.parse
        parser.message
      rescue StandardError
        nil
      end

      attr_reader :message

      def on_parse_error(message)
        @message = message if @message.nil?
      end
    end
  end
end
