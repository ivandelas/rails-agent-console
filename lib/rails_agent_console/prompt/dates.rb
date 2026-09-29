# frozen_string_literal: true

module RailsAgentConsole
  module Prompt
    module Dates
      MONTHS = %w[january february march april may june july august september october november december].freeze
      MONTH_YEAR = /\b(#{MONTHS.join("|")})\s+((?:19|20)\d{2})\b/i
      YEAR = %r{(?<![\d./-])((?:19|20)\d{2})(?![\d./-])}

      module_function

      def annotate(prompt)
        ranges = month_ranges(prompt) + year_ranges(prompt)
        return prompt if ranges.empty?

        "#{prompt}\n\nDates in this request, as ranges to filter on: #{ranges.join("; ")}."
      end

      def month_ranges(prompt)
        prompt.scan(MONTH_YEAR).map do |month, year|
          number = MONTHS.index(month.downcase) + 1
          %(#{month.capitalize} #{year} is Time.zone.parse("#{year}-#{format("%02d", number)}-01").all_month)
        end.uniq
      end

      def year_ranges(prompt)
        within_months = prompt.scan(MONTH_YEAR).map(&:last)
        (prompt.scan(YEAR).flatten.uniq - within_months).map do |year|
          %(#{year} is Time.zone.parse("#{year}-01-01").all_year)
        end
      end
    end
  end
end
