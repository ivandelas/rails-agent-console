# frozen_string_literal: true

module RailsAgentConsole
  module Diagnosis
    MISSING_COLUMN = /column "([^"]+)" does not exist/
    NESTED_AGGREGATE = /aggregate function calls cannot be nested/
    MISSING_GROUP = /column "([^"]+)" must appear in the GROUP BY clause/
    MISSING_ASSOCIATION = /Can't join '([^']+)' to association named '([^']+)'/
    MISSING_TABLE = /missing FROM-clause entry for table "([^"]+)"/
    ALIAS_IN_CLAUSE = /syntax error at or near "AS"/
    HASH_CHAIN = /undefined method [`']([^`']+)['`] for .*Hash/m
    NOT_A_TIME = /invalid input syntax for type (timestamp|date)[^:]*: "([^"]*)"/
    TYPE_MISMATCH = /operator does not exist: (\w[\w ]*) = (\w[\w ]*)/

    class << self
      def hint(code, message)
        text = message.to_s
        alias_hint(code, text) || nested_aggregate_hint(text) || group_by_hint(text) ||
          association_hint(text) || missing_table_hint(text) || type_mismatch_hint(text) ||
          alias_in_clause_hint(text) || hash_chain_hint(text) || not_a_time_hint(text) ||
          Extra.hint(code, text)
      end

      private

      def alias_hint(code, message)
        name = message[MISSING_COLUMN, 1]
        return unless name && aliased?(code, name)

        "`#{name}` is an alias from select(...). SQL cannot see it anywhere else in the " \
          "same query, so repeat the expression instead of naming the alias."
      end

      def aliased?(code, name)
        code.to_s.match?(/\bAS\s+"?#{Regexp.escape(name)}"?\b/i)
      end

      def nested_aggregate_hint(message)
        return unless NESTED_AGGREGATE.match?(message)

        "One aggregate cannot wrap another. Divide two separate aggregates instead, " \
          "such as Model.count.to_f / Model.distinct.count(:customer_id)."
      end

      def group_by_hint(message)
        name = message[MISSING_GROUP, 1]
        return unless name

        "Every column that is selected has to be either grouped by or wrapped in an " \
          "aggregate. Group by `#{name}` as well, or leave it out of the select."
      end

      def association_hint(message)
        match = MISSING_ASSOCIATION.match(message)
        return unless match

        owner, name = match.captures
        return column_hint(owner, name) if column?(owner, name)

        ["There is no `#{name}` association on #{owner}, and there never will be: nothing",
         "declares it. #{ways_around(owner, name)}"].join(" ")
      end

      def column_hint(owner, name)
        "`#{name}` is a column on #{owner}, not an association. Read it or filter on it " \
          "directly -- #{owner}.where(#{name}: nil) -- with no join at all."
      end

      def column?(owner, name)
        Schema.find(owner)&.column_names&.include?(name.to_s) || false
      rescue StandardError
        false
      end

      def not_a_time_hint(message)
        type, value = NOT_A_TIME.match(message)&.captures
        return unless type

        "A #{type} column was compared with #{value.inspect}, which is not a #{type}. A condition " \
          "on part of a date is evaluated per row in SQL: " \
          "where(\"EXTRACT(DOW FROM created_at) IN (0, 6)\") for weekends, EXTRACT(HOUR FROM ...) for hours."
      end

      def hash_chain_hint(message)
        name = message[HASH_CHAIN, 1]
        return unless name

        "count, sum and average on a grouped relation return a Hash of results, so `#{name}` " \
          "has nothing to act on. Chain everything onto the relation first and aggregate last: " \
          "group(:source).order(Arel.sql(\"AVG(LENGTH(query)) DESC\")).average(Arel.sql(\"LENGTH(query)\"))."
      end

      def ways_around(owner, name)
        shared = Extra.shared_column(owner, name)
        return shared if shared

        other = referring_model(owner, name)
        return "Answer it from the model that declares the belongs_to instead." unless other

        "Either start from #{other[:model]} and join back -- " \
          "#{other[:model]}.joins(:#{other[:association]}) -- or keep #{owner} as the subject and " \
          "filter with a subquery: #{owner}.where(id: #{other[:model]}.select(:#{other[:foreign_key]})), " \
          "or where.not for the ones without."
      end

      def referring_model(owner, name)
        inbound = Schema.find(owner)&.inbound
        return if inbound.nil? || inbound.empty?

        inbound.find { |reference| same_model?(reference[:model], name) } || inbound.first
      rescue StandardError
        nil
      end

      def missing_table_hint(message)
        table = message[MISSING_TABLE, 1]
        return unless table

        "The query reads columns from `#{table}` without that table being in the query. " \
          "Move the condition into a subquery on #{table} -- counting rows per owner is " \
          "where(id: Other.group(:owner_id).having(Arel.sql(\"COUNT(*) > 10\")).select(:owner_id)) -- " \
          "or drop it: the column you want may well be on the table you already select from."
      end

      def alias_in_clause_hint(message)
        return unless ALIAS_IN_CLAUSE.match?(message)

        "Only a select list may name an alias with AS. Pass group(...) and order(...) the " \
          "expression itself, as a separate argument per column: " \
          "group(Arel.sql(\"EXTRACT(YEAR FROM created_at)\"), :source).count."
      end

      def type_mismatch_hint(message)
        left, right = TYPE_MISMATCH.match(message)&.captures
        return unless left

        "A #{left.strip} column is being compared with a #{right.strip} one, which is what " \
          "where(id: Model.select(:some_string)) does. Compare columns that hold the same kind " \
          "of value: if one table refers to another by email rather than by id, join the emails."
      end

      def same_model?(model, name)
        model.to_s.split("::").last.downcase == name.to_s.delete("_").sub(/s\z/, "")
      end
    end
  end
end

require_relative "diagnosis/extra"
