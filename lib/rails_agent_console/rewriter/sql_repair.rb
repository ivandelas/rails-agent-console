# frozen_string_literal: true

module RailsAgentConsole
  module Rewriter
    class SqlRepair
      STRING_LITERAL = /"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'/
      AGGREGATE_WITHOUT_PARENS = /\b(AVG|SUM|MIN|MAX|COUNT)\s+(\w+\((?:[^()]|\([^()]*\))*\))/i
      POSTFIX_LENGTH = /\b((?:\w+\.)?\w+(?:::\w+)?)\s+length\b(?!\s*\()/i
      AVERAGE_OF = /\bAVG\(\s*((?:\w+\.)?\w+)\s*\)/i
      PAD_NUMBER = /\b([LR]PAD)\(\s*(EXTRACT\([^()]*\))\s*,/i
      INTEGER_DIVISION = %r{
        \b((?:SUM|COUNT)\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\))
        (\s*/\s*)
        (?=(?:COUNT|SUM|NULLIF)\s*\()
      }xi
      ALREADY_DECIMAL = /(?:\d\.\d+\s*\*\s*|::(?:float|numeric|decimal|real)\w*\s*\(?\s*)\z/i
      SQL_WORDS = %w[select where and or not by as on from having order group].to_set.freeze
      TIME_TYPES = %w[datetime timestamp timestamptz date time].to_set.freeze
      NO_ALIAS = %w[group order reorder].to_set.freeze

      NOTES = {
        parens: "an aggregate takes its argument in parentheses, AVG(LENGTH(x))",
        length: "LENGTH is a function, LENGTH(x), not a postfix",
        alias: "AS names a selected column; GROUP BY and ORDER BY take the expression alone",
        pad: "LPAD pads text, so the number from EXTRACT is cast to text first",
        division: "a count divided by a count is whole-number division, so it is multiplied by 1.0 first",
        epoch: "SQL has no average of a timestamp, so it averages EXTRACT(EPOCH FROM ...), " \
               "which orders the same way"
      }.freeze

      def initialize(chain, model)
        @chain = chain
        @model = model
        @fixed = []
      end

      def rewrite
        calls = @chain.calls.map { |call| JOINS.key?(call.name) ? call : repair(call) }
        return if @fixed.empty?

        [@chain.with_calls(calls), "In the SQL: #{@fixed.uniq.map { |key| NOTES[key] }.join("; ")}."]
      end

      private

      def repair(call)
        text = call.text.gsub(STRING_LITERAL) do |literal|
          quote = literal[0]
          "#{quote}#{fix(literal[1...-1], call.name)}#{quote}"
        end
        text == call.text ? call : Chain::Call.new(call.name, text)
      end

      def fix(sql, name)
        sql = replace(sql, AGGREGATE_WITHOUT_PARENS, :parens) { |match| "#{match[1]}(#{match[2]})" }
        sql = replace(sql, POSTFIX_LENGTH, :length) { |match| postfix_length(match) }
        sql = replace(sql, AVERAGE_OF, :epoch) { |match| average_of(match) }
        sql = replace(sql, PAD_NUMBER, :pad) { |match| "#{match[1]}(#{match[2]}::text," }
        sql = replace(sql, INTEGER_DIVISION, :division) { |match| decimal_division(match) }
        NO_ALIAS.include?(name) ? drop_aliases(sql) : sql
      end

      def replace(sql, pattern, key)
        sql.gsub(pattern) do
          match = Regexp.last_match
          replacement = yield(match)
          @fixed << key unless replacement == match[0]
          replacement
        end
      end

      def decimal_division(match)
        return match[0] if match.pre_match.match?(ALREADY_DECIMAL)

        "#{match[1]} * 1.0#{match[2]}"
      end

      def postfix_length(match)
        SQL_WORDS.include?(match[1].downcase) ? match[0] : "LENGTH(#{match[1]})"
      end

      def average_of(match)
        time_column?(match[1]) ? "AVG(EXTRACT(EPOCH FROM #{match[1]}))" : match[0]
      end

      def time_column?(reference)
        table, column = reference.include?(".") ? reference.split(".", 2) : [nil, reference]
        model = table ? Schema.models.find { |candidate| candidate.table == table } : @model
        type = model&.columns&.find { |name, _| name == column }&.[](1)
        TIME_TYPES.include?(type.to_s)
      end

      def drop_aliases(sql)
        depth = 0
        quoted = false
        out = +""
        index = 0
        while index < sql.length
          char = sql[index]
          quoted = !quoted if char == "'"
          depth += { "(" => 1, ")" => -1 }.fetch(char, 0) unless quoted
          if !quoted && depth.zero? && (alias_match = sql[index..].match(/\A\s+AS\s+"?\w+"?/i))
            @fixed << :alias
            index += alias_match[0].length
            next
          end
          out << char
          index += 1
        end
        out
      end
    end
  end
end
