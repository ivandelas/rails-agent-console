# frozen_string_literal: true

module RailsAgentConsole
  module Rewriter
    class Qualifier
      SQL_CALLS = (RELATION + AGGREGATES + %w[pluck pick]).freeze
      SUBQUERY = /\(\s*SELECT\b/i
      STRING_LITERAL = /"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'/

      def initialize(chain, model)
        @chain = chain
        @model = model
        @renamed = {}
        @qualified = []
      end

      def rewrite
        calls = sql_calls
        tables = joined_tables(calls)
        return if tables.empty?

        @ambiguous = ambiguous_columns(tables)
        rewritten = calls.map { |call| JOINS.key?(call.name) ? call : qualify(call) }
        return if @renamed.empty? && @qualified.empty?

        [@chain.with_calls(rewritten + @chain.calls.drop(calls.size)), note]
      end

      private

      def sql_calls
        count = @chain.calls.index { |call| !SQL_CALLS.include?(call.name) } || @chain.calls.size
        @chain.calls.first(count)
      end

      def joined_tables(calls)
        Joined.tables(calls, @model)
      end

      def ambiguous_columns(tables)
        joined = tables.values.uniq.flat_map { |table| Joined.model_for(table)&.column_names || [] }
        (@model.column_names & joined).to_set
      end

      def qualify(call)
        text = call.text.gsub(STRING_LITERAL) do |literal|
          quote = literal[0]
          "#{quote}#{rewrite_sql(literal[1...-1])}#{quote}"
        end
        text == call.text ? call : Chain::Call.new(call.name, text)
      end

      def rewrite_sql(sql)
        outside_subqueries(sql) do |part|
          part = rename_associations(part)
          @ambiguous.reduce(part) { |current, column| qualify_column(current, column) }
        end
      end

      def outside_subqueries(sql)
        output = +""
        rest = sql
        while (start = rest =~ SUBQUERY)
          finish = closing_paren(rest, start)
          output << yield(rest[0...start]) << rest[start..finish]
          rest = rest[(finish + 1)..]
        end
        output << yield(rest)
      end

      def closing_paren(sql, start)
        depth = 0
        (start...sql.length).each do |index|
          depth += 1 if sql[index] == "("
          depth -= 1 if sql[index] == ")"
          return index if depth.zero?
        end
        sql.length - 1
      end

      def rename_associations(sql)
        joined_names.reduce(sql) do |current, (name, table)|
          current.gsub(/(?<![\w."])#{Regexp.escape(name)}\.(?=\w)/) do
            @renamed[name] = table
            "#{table}."
          end
        end
      end

      def joined_names
        @joined_names ||= joined_tables(sql_calls).reject { |name, table| name == table }
      end

      def qualify_column(sql, column)
        sql.gsub(/(?<![\w."'])(?<!AS\s)(?<!as\s)#{Regexp.escape(column)}(?![\w"'(])/) do
          @qualified << column unless @qualified.include?(column)
          "#{@model.table}.#{column}"
        end
      end

      def note
        parts = []
        if @qualified.any?
          parts << "#{list(@qualified)} is in more than one of the joined tables, so it now " \
                   "reads #{@model.table}.#{@qualified.first}, the table the query starts from"
        end
        @renamed.each { |name, table| parts << "`#{name}.` is the association; SQL needs the table, #{table}" }
        "#{parts.join("; ")}."
      end

      def list(columns)
        columns.map { |column| "`#{column}`" }.join(", ")
      end
    end
  end
end
