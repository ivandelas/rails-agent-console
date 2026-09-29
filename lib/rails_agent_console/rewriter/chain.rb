# frozen_string_literal: true

module RailsAgentConsole
  module Rewriter
    class Chain
      RECEIVER = /\A[A-Za-z_]\w*(?:::[A-Z]\w*)*\z/
      CALL_NAME = /\A\.\s*(\w+[?!]?)/

      Call = Struct.new(:name, :text) do
        def symbol_arguments
          inner = text[/\A\.\s*\w+[?!]?\s*\((.*)\)\s*\z/m, 1]
          return unless inner&.match?(/\A\s*:\w+(?:\s*,\s*:\w+)*\s*\z/)

          inner.scan(/:(\w+)/).flatten
        end
      end

      attr_reader :receiver, :calls

      def self.parse(code)
        text = code.to_s.strip
        return if text.empty? || text.match?(/\bdo\b|;/)

        pieces = Scanner.new(text).pieces
        return if pieces.nil? || pieces.size < 2 || !pieces.first.match?(RECEIVER)

        calls = pieces.drop(1).map { |piece| Call.new(piece[CALL_NAME, 1], piece) }
        return unless calls.all? { |call| call.name && Scanner.call_shape?(call.text.sub(CALL_NAME, "")) }

        new(pieces.first, calls)
      end

      def initialize(receiver, calls)
        @receiver = receiver
        @calls = calls
      end

      def with_calls(calls)
        self.class.new(receiver, calls)
      end

      def to_s
        receiver + calls.map(&:text).join
      end

      class Scanner
        def self.call_shape?(rest)
          new(rest).call_shape?
        end

        def self.single_argument?(text)
          new(text).single_argument?
        end

        def initialize(text)
          @text = text
          @depth = 0
          @quote = nil
          @escaped = false
        end

        def pieces
          cuts = []
          @text.each_char.with_index do |char, index|
            next if in_string?(char)
            return nil unless balanced_after?(char)

            cuts << index if char == "." && @depth.zero? && call_dot?(index)
          end
          return unless @depth.zero? && @quote.nil?

          ([0] + cuts + [@text.length]).each_cons(2).map { |from, to| @text[from...to].strip }
        end

        def call_shape?
          @text.each_char do |char|
            return false if @quote.nil? && @depth.zero? && !char.match?(/[\s(){}]/)
            next if in_string?(char)
            return false unless balanced_after?(char)
          end
          @depth.zero? && @quote.nil?
        end

        def single_argument?
          @text.each_char do |char|
            next if in_string?(char)
            return false unless balanced_after?(char)
            return false if char == "," && @depth.zero?
          end
          @depth.zero? && @quote.nil?
        end

        private

        def in_string?(char)
          return string_opened?(char) if @quote.nil?

          if @escaped then @escaped = false
          elsif char == "\\" then @escaped = true
          elsif char == @quote then @quote = nil
          end
          true
        end

        def string_opened?(char)
          return false unless ["'", '"'].include?(char)

          @quote = char
          true
        end

        def balanced_after?(char)
          @depth += 1 if "([{".include?(char)
          @depth -= 1 if ")]}".include?(char)
          @depth >= 0
        end

        def call_dot?(index)
          before = index.positive? ? @text[index - 1] : ""
          after = @text[index + 1].to_s
          before != "." && after != "." && !before.match?(/\d/) && after.match?(/[\s\w]/)
        end
      end
    end
  end
end
