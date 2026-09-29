# frozen_string_literal: true

module RailsAgentConsole
  class QueryValidator
    module SensitiveColumns
      PATTERN = /\A(?:\w*password\w*|\w+_digest|(?:\w+_)?token|\w*secret\w*|(?:\w+_)?api_key|otp_\w+)\z/i
      PRESENCE_TEST = /(?<![\w.:])\w+:\s*nil\b(?!\s*\.)/
      TOKENS = %i[on_ident on_label on_tstring_content on_symbol].freeze

      module_function

      def named_in(code)
        Ripper.lex(code.gsub(PRESENCE_TEST, "")).flat_map { |(_, type, text)| TOKENS.include?(type) ? words(text) : [] }
              .grep(PATTERN).uniq
      end

      def words(text)
        text.scan(/[A-Za-z_]\w*/)
      end
    end
  end
end
