# frozen_string_literal: true

require "json"

module RailsAgentConsole
  class Proposal
    attr_reader :code, :explanation, :assumptions, :raw, :validation, :corrections

    def self.parse(raw, write_mode: false)
      payload = extract_json(raw) || { "code" => extract_code_block(raw) }
      code = payload["code"].to_s.strip

      new(
        code: code,
        explanation: payload["explanation"],
        assumptions: Array(payload["assumptions"]),
        raw: raw,
        write_mode: write_mode
      )
    end

    NO_OP_TAIL = /\.\s*(?:load|all)\s*\z/

    BARE_COUNT_TAIL = /\.\s*count\s*(?:\(\s*\))?\s*\z/

    FENCED = /\A```[a-zA-Z]*[ \t]*\r?\n?(.*?)```\z/m

    def initialize(code:, explanation: nil, assumptions: [], raw: nil, write_mode: false)
      rewritten = Rewriter.apply(count_all(trim_no_ops(unfence(code))))
      @code = rewritten.code
      @corrections = rewritten.notes
      @explanation = explanation
      @assumptions = assumptions
      @raw = raw
      @validation = QueryValidator.validate(@code, write_mode: write_mode)
    end

    def safe?
      @validation.valid?
    end

    def destructive?
      @validation.destructive?
    end

    def writes?
      @validation.writes?
    end

    def violations
      @validation.violations
    end

    def models
      @validation.models
    end

    NO_CODE = ["", "nil", "null", "none", "n/a", "{}", "[]", "0"].freeze

    NO_QUERY = /\A[A-Z]\w*(?:::[A-Z]\w*)*\s*\.\s*none\z/

    def empty?
      NO_CODE.include?(@code.downcase) || NO_QUERY.match?(@code) || statements.empty?
    end

    private

    def unfence(code)
      text = code.to_s.strip
      text = Regexp.last_match(1).to_s.strip if FENCED.match(text)
      text.gsub(/\A`+|`+\z/, "").strip
    end

    def trim_no_ops(code)
      loop do
        trimmed = code.sub(NO_OP_TAIL, "")
        break unless trimmed != code && trimmed.include?(".")

        code = trimmed
      end
      code
    end

    def count_all(code)
      return code unless BARE_COUNT_TAIL.match?(code) && several_selected?(code)

      code.sub(BARE_COUNT_TAIL, ".count(:all)")
    end

    def several_selected?(code)
      code.to_s.enum_for(:scan, /\.\s*select\s*\(/).any? do
        several_columns?(code[Regexp.last_match.end(0)..])
      end
    end

    Scan = Struct.new(:quote, :sql, :ruby)

    def several_columns?(arguments)
      scan = Scan.new(nil, 0, 0)

      arguments.to_s.each_char do |char|
        verdict = scan.quote ? read_in_string(scan, char) : read_in_ruby(scan, char)
        return verdict unless verdict.nil?
      end
      false
    end

    def read_in_string(scan, char)
      case char
      when scan.quote then scan.quote = nil
      when "(" then scan.sql += 1
      when ")" then scan.sql -= 1 unless scan.sql.zero?
      when "," then return true if scan.sql.zero?
      end
      nil
    end

    def read_in_ruby(scan, char)
      case char
      when "'", '"' then scan.quote = char
      when "(" then scan.ruby += 1
      when ")"
        return false if scan.ruby.zero? # the select call ends here

        scan.ruby -= 1
      when "," then return true if scan.sql.zero?
      end
      nil
    end

    def statements
      @code.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#") }
    end

    class << self
      private

      def extract_json(raw)
        candidate = balanced_object(strip_fences(raw.to_s.strip))
        return unless candidate

        parse_json(candidate) || salvage(candidate)
      end

      def strip_fences(text)
        text.gsub(/\A```[a-zA-Z]*[ \t]*\r?\n?/, "").gsub(/```\z/, "").strip
      end

      def balanced_object(text)
        start = text.index("{")
        return unless start

        depth = 0
        in_string = false
        escaped = false
        text[start..].each_char.with_index do |char, index|
          if in_string
            if escaped then escaped = false
            elsif char == "\\" then escaped = true
            elsif char == '"' then in_string = false
            end
            next
          end

          case char
          when '"' then in_string = true
          when "{" then depth += 1
          when "}"
            depth -= 1
            return text[start, index + 1] if depth.zero?
          end
        end
        nil
      end

      def salvage(text)
        code = json_string(text, "code")
        return if code.nil?

        { "code" => code, "explanation" => json_string(text, "explanation") }
      end

      def json_string(text, key)
        raw = text[/"#{key}"\s*:\s*"((?:[^"\\]|\\.)*)"/, 1]
        return if raw.nil?

        JSON.parse("\"#{raw}\"")
      rescue JSON::ParserError
        raw
      end

      def parse_json(candidate)
        payload = JSON.parse(candidate)
        payload if payload.is_a?(Hash) && payload.key?("code")
      rescue JSON::ParserError
        nil
      end

      def extract_code_block(raw)
        text = raw.to_s
        fenced = text[/```[a-zA-Z]*[ \t]*\r?\n(.*?)```/m, 1]
        return fenced.strip if fenced

        text.strip
      end
    end
  end
end
