# frozen_string_literal: true

module RailsAgentConsole
  module Rewriter
    class Arguments
      ARGUMENTS = /\A\.\s*\w+[?!]?\s*\((.*)\)\s*\z/m
      STRING_ARGUMENT = /\A\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')\s*\z/
      COLUMN_PAIR = /\A\s*(\w+):\s*([a-z_]\w*)\s*\z/
      SYMBOL_PAIR = /\A\s*(\w+):\s*:(\w+)\s*\z/
      SINGLE_PAIR = /\A\s*(\w+):\s*(.+?)\s*\z/m
      HASH_KEY = /(?<![\w.:])(\w+):\s*\{/
      ORDER_COLUMN = /\A\s*:?(\w+)(?::\s*:(asc|desc))?\s*\z/i
      WEEKDAY = /\A\s*(\w+):\s*(.*\bwday\b.*?)\s*\z/m
      WEEKDAY_TEST = /(?:Time\.(?:current|now)|Date\.(?:current|today))\.wday\s*==\s*([0-6])/
      RAW_SQL_CALLS = %w[pluck pick order reorder].to_set.freeze
      COMPARE_CALLS = %w[where not rewhere].to_set.freeze
      DIRECTIONS = %w[asc desc].to_set.freeze
      VALUES = %w[true false nil].to_set.freeze

      NOTES = {
        compare: "a hash value is a Ruby value, so comparing two columns is written in SQL",
        weekday: "Time.current.wday is today's weekday, worked out once; the day of each row is EXTRACT(DOW ...)",
        order: "ordering by a joined table's column is written as table.column",
        joined_key: "the column belongs to a joined table, so the condition names that table",
        table_key: "a condition names the joined table rather than the association, " \
                   "so every reference to it agrees",
        order_in_group: "a grouped query can only order by what it groups or aggregates, so it orders by MIN(...)",
        raw_sql: "Rails only accepts an SQL expression in pluck and order through Arel.sql",
        count: "counting a joined table counts its id",
        nest: "an association of a joined model is joined through it",
        bare: "an association is named with a symbol, not a bare word"
      }.freeze
      ASSOCIATION_CALLS = (JOINS.keys + %w[includes preload eager_load]).to_set.freeze
      BARE_WORDS = /\A\s*[a-z_]\w*(?:\s*,\s*[a-z_]\w*)*\s*\z/

      def initialize(chain, model)
        @chain = chain
        @model = model
        @fixed = []
      end

      def rewrite
        calls = nest_joins(@chain.calls)
        tables = Joined.tables(calls, @model)
        @grouped = calls.select { |call| call.name == "group" }.map(&:symbol_arguments)
        calls = calls.map { |call| fix(call, tables) }
        return if @fixed.empty?

        [@chain.with_calls(calls), "#{@fixed.uniq.map { |key| NOTES[key] }.join("; ").sub(/\A./, &:upcase)}."]
      end

      private

      def bare_association(call, inner)
        return unless ASSOCIATION_CALLS.include?(call.name) && inner.match?(BARE_WORDS)

        names = inner.split(",").map(&:strip)
        return unless (names - @model.association_names).empty?

        @fixed << :bare
        names.map { |name| ":#{name}" }.join(", ")
      end

      def fix(call, tables)
        original = call.text[ARGUMENTS, 1]
        return call if original.nil?

        inner = table_keys(call, original, tables)
        replacement = bare_association(call, inner) || compare_columns(call, inner) || weekday(call, inner) ||
                      joined_key(call, inner, tables) ||
                      order_through(call, inner, tables) || order_in_group(call, inner) || wrap_sql(call, inner) ||
                      count_joined(call, inner, tables) || (inner unless inner == original)
        replacement ? Chain::Call.new(call.name, ".#{call.name}(#{replacement})") : call
      end

      def table_keys(call, inner, tables)
        return inner unless COMPARE_CALLS.include?(call.name)

        inner.gsub(HASH_KEY) do |key|
          table = tables[Regexp.last_match(1)]
          next key if table.nil? || table == Regexp.last_match(1)

          @fixed << :table_key
          "#{table}: {"
        end
      end

      def compare_columns(call, inner)
        left, right = inner.match(COLUMN_PAIR)&.captures
        return unless COMPARE_CALLS.include?(call.name) && left && !VALUES.include?(right)
        return unless ([left, right] - @model.column_names).empty?

        fixed(:compare, %("#{@model.table}.#{left} = #{@model.table}.#{right}"))
      end

      def weekday(call, inner)
        column, condition = inner.match(WEEKDAY)&.captures
        return unless COMPARE_CALLS.include?(call.name) && column && @model.column_names.include?(column)
        return unless condition.gsub(WEEKDAY_TEST, "").match?(/\A[\s()|]*\z/)

        days = condition.scan(WEEKDAY_TEST).flatten.uniq.join(", ")
        fixed(:weekday, %("EXTRACT(DOW FROM #{@model.table}.#{column}) IN (#{days})"))
      end

      def joined_key(call, inner, tables)
        key, value = inner.match(SINGLE_PAIR)&.captures
        return unless COMPARE_CALLS.include?(call.name) && key && !@model.column_names.include?(key)
        return unless Chain::Scanner.single_argument?(value)

        owners = tables.values.uniq.select { |table| Joined.model_for(table)&.column_names&.include?(key) }
        fixed(:joined_key, "#{owners.first}: { #{key}: #{value} }") if owners.size == 1
      end

      def order_through(call, inner, tables)
        name, column = inner.match(SYMBOL_PAIR)&.captures
        return unless RAW_SQL_CALLS.include?(call.name) && name && !DIRECTIONS.include?(column.downcase)

        table = tables[name] || (name if tables.value?(name))
        return unless table && Joined.model_for(table)&.column_names&.include?(column)

        fixed(:order, %("#{table}.#{column}"))
      end

      def order_in_group(call, inner)
        column, direction = inner.match(ORDER_COLUMN)&.captures
        return unless %w[order reorder].include?(call.name) && column && grouped_elsewhere?(column)

        suffix = direction ? " #{direction.upcase}" : ""
        fixed(:order_in_group, %(Arel.sql("MIN(#{@model.table}.#{column})#{suffix}")))
      end

      def grouped_elsewhere?(column)
        return false if @grouped.empty? || @grouped.any?(&:nil?)

        !@grouped.flatten.include?(column) && @model.column_names.include?(column)
      end

      def wrap_sql(call, inner)
        literal = inner[STRING_ARGUMENT, 1]
        return unless RAW_SQL_CALLS.include?(call.name) && literal&.include?("(")

        fixed(:raw_sql, "Arel.sql(#{literal})")
      end

      def count_joined(call, inner, tables)
        name = inner[/\A\s*:(\w+)\s*\z/, 1]
        return unless call.name == "count" && name && !@model.column_names.include?(name)

        table = joined_table(name.delete_suffix("_id"), tables)
        table && fixed(:count, %("#{table}.id"))
      end

      def joined_table(name, tables)
        tables[name] || tables.values.find { |table| [name, name.pluralize].include?(table) }
      end

      def nest_joins(calls)
        joined = []
        calls.map do |call|
          names = JOINS.key?(call.name) && call.symbol_arguments
          next call unless names

          nested = names.map { |name| nest(name, joined) }
          joined.concat(names)
          nested == names ? call : nested_call(call, names, nested)
        end
      end

      def nest(name, joined)
        return name if Joined.target(@model, name) || @model.inbound.any? { |ref| ref[:table].to_s == name }

        parent = joined.find do |candidate|
          through = Joined.target(@model, candidate)
          through && Joined.target(through, name)
        end
        parent ? "#{parent}: :#{name}" : name
      end

      def nested_call(call, names, nested)
        @fixed << :nest
        plain = nested.select.with_index { |item, index| item == names[index] }.map { |name| ":#{name}" }
        pairs = nested.reject.with_index { |item, index| item == names[index] }
        Chain::Call.new(call.name, ".#{call.name}(#{(plain + pairs).join(", ")})")
      end

      def fixed(key, replacement)
        @fixed << key
        replacement
      end
    end
  end
end
