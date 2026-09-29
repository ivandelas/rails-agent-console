# frozen_string_literal: true

module RailsAgentConsole
  module Rewriter
    module DateRanges
      INCLUSIVE_END = /
        (?<![.])\.\.\s*
        (?<date>Time\.zone\.parse\((?<quote>["'])\d{4}-\d{2}-\d{2}\k<quote>\))
        (?!\s*\.\s*end_of_day)
      /x
      NOTE = "A range that ended on a date stopped at midnight and missed that day, so it now runs to end_of_day."

      module_function

      def fix(code)
        fixed = code.gsub(INCLUSIVE_END) { "..#{Regexp.last_match[:date]}.end_of_day" }
        fixed == code ? [code, nil] : [fixed, NOTE]
      end
    end
  end
end
