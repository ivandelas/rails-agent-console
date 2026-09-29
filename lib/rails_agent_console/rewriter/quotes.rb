# frozen_string_literal: true

require "ripper"

module RailsAgentConsole
  module Rewriter
    module Quotes
      SINGLE_QUOTED_SQL = /(\w\()'(.*?)'(\)(?=[.)\s,]|\z))/m
      ARGUMENT_BREAK = /'\s*,/
      NOTE = "SQL with its own single quotes was inside a single-quoted Ruby string, " \
             "so the Ruby string now uses double quotes."

      module_function

      def fix(code)
        broken = Ripper.sexp(code).nil?
        fixed = code.gsub(SINGLE_QUOTED_SQL) do
          prefix, sql, suffix = Regexp.last_match.captures
          nested?(sql, broken) ? %(#{prefix}"#{sql}"#{suffix}) : Regexp.last_match(0)
        end
        fixed != code && Ripper.sexp(fixed) ? [fixed, NOTE] : [code, nil]
      end

      def nested?(sql, broken)
        sql.include?("'") && !sql.include?('"') && (broken || !sql.match?(ARGUMENT_BREAK))
      end
    end
  end
end
