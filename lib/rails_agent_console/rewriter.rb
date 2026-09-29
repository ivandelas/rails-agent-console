# frozen_string_literal: true

require "set"

require_relative "rewriter/chain"
require_relative "rewriter/date_ranges"

module RailsAgentConsole
  module Rewriter
    Result = Struct.new(:code, :notes)

    RELATION = %w[
      all where not or and rewhere unscope joins left_joins left_outer_joins includes
      preload eager_load references group having order reorder limit offset distinct
      select readonly none
    ].to_set.freeze

    JOINS = { "joins" => "INNER", "left_joins" => "LEFT OUTER", "left_outer_joins" => "LEFT OUTER" }.freeze
    AGGREGATES = %w[count sum average minimum maximum calculate].to_set.freeze
    MOVABLE = %w[where having order reorder limit offset].to_set.freeze
    REWRITES = %i[
      spell_out_joins repair_arguments repair_sql qualify_columns aggregate_last first_group drop_distinct
    ].freeze

    class << self
      def apply(code)
        code, quote_note = Quotes.fix(code.to_s)
        code, range_note = DateRanges.fix(code)
        notes = [quote_note, range_note].compact
        chain = Chain.parse(code)
        return Result.new(code, notes) if chain.nil?

        rewritten_notes = REWRITES.filter_map do |name|
          rewritten, note = method(name).call(chain)
          next if rewritten.nil?

          chain = rewritten
          note
        end
        Result.new(rewritten_notes.empty? ? code : chain.to_s, notes + rewritten_notes)
      end

      private

      def spell_out_joins(chain)
        model = Schema.find(chain.receiver)
        return if model.nil? || model.inbound.empty?

        spelled = []
        calls = relation_calls(chain).flat_map do |call|
          replacement = spell_out(call, model)
          next [call] if replacement.nil?

          spelled.concat(replacement[:tables])
          replacement[:calls]
        end
        return if spelled.empty?

        [chain.with_calls(calls + chain.calls.drop(calls_scanned(chain))), joins_note(model, spelled)]
      end

      def spell_out(call, model)
        kind = JOINS[call.name]
        names = kind && call.symbol_arguments
        return if names.nil?

        references = names.to_h { |name| [name, missing_association(model, name)] }
        return if references.values.none?

        missing = references.values.compact
        kept = references.select { |_, reference| reference.nil? }.keys
        calls = kept_joins(call, kept) + missing.map { |reference| sql_join(kind, model, reference) }
        { calls: calls, tables: missing.map { |reference| reference[:table] } }
      end

      def kept_joins(call, names)
        return [] if names.empty?

        [Chain::Call.new(call.name, ".#{call.name}(#{names.map { |name| ":#{name}" }.join(", ")})")]
      end

      def missing_association(model, name)
        return if model.association_names.include?(name)

        model.inbound.find { |reference| reference[:table].to_s == name }
      end

      def sql_join(kind, model, reference)
        on = "#{reference[:table]}.#{reference[:foreign_key]} = #{model.table}.#{primary_key(model)}"
        Chain::Call.new("joins", %(.joins("#{kind} JOIN #{reference[:table]} ON #{on}")))
      end

      def primary_key(model)
        column = model.columns.find { |_, _, extra| extra.to_s.include?("pk") }
        column ? column.first : "id"
      end

      def joins_note(model, tables)
        "#{model.name} has no has_many for #{tables.join(" or ")}, so the join is written out " \
          "in SQL, the same one the association would have built."
      end

      def drop_distinct(chain)
        Distinct.drop(chain)
      end

      def qualify_columns(chain)
        model = Schema.find(chain.receiver)
        model && Qualifier.new(chain, model).rewrite
      end

      def repair_arguments(chain)
        model = Schema.find(chain.receiver)
        model && Arguments.new(chain, model).rewrite
      end

      def repair_sql(chain)
        SqlRepair.new(chain, Schema.find(chain.receiver)).rewrite
      end

      def aggregate_last(chain)
        index = chain.calls.index { |call| AGGREGATES.include?(call.name) }
        return if index.nil?

        before = chain.calls.first(index)
        after = chain.calls.drop(index + 1)
        return unless misplaced?(before, after)

        aggregate = chain.calls[index]
        [chain.with_calls(before + after + [aggregate]), aggregate_note(aggregate, after)]
      end

      def first_group(chain)
        index = calls_scanned(chain)
        return unless chain.calls[index]&.text&.match?(/\A\.\s*first\s*\z/)

        column = grouped_column(chain.calls.first(index))
        return if column.nil?

        rest = chain.calls.drop(index + 1)
        rest = rest.drop(1) if rest.first&.text&.match?(/\A\.\s*#{column}\s*\z/)
        pluck = Chain::Call.new("pluck", ".limit(1).pluck(:#{column}).first")
        [chain.with_calls(chain.calls.first(index) + [pluck] + rest), first_group_note(column)]
      end

      def grouped_column(calls)
        columns = calls.select { |call| call.name == "group" }.flat_map { |call| call.symbol_arguments || [] }
        columns.first if columns.size == 1
      end

      def first_group_note(column)
        "`first` on a grouped relation orders by id, which the GROUP BY does not contain, " \
          "so the top group's #{column} is plucked instead."
      end

      def misplaced?(before, after)
        after.any? && after.all? { |call| MOVABLE.include?(call.name) } &&
          before.all? { |call| RELATION.include?(call.name) }
      end

      def aggregate_note(aggregate, moved)
        names = moved.map { |call| "`#{call.name}`" }.uniq.join(" and ")
        "#{names} came after `#{aggregate.name}`, which returns a result rather than a " \
          "relation, so they now run before it."
      end

      def relation_calls(chain)
        chain.calls.first(calls_scanned(chain))
      end

      def calls_scanned(chain)
        chain.calls.index { |call| !RELATION.include?(call.name) } || chain.calls.size
      end
    end
  end
end

require_relative "rewriter/distinct"
require_relative "rewriter/joined"
require_relative "rewriter/quotes"
require_relative "rewriter/arguments"
require_relative "rewriter/qualifier"
require_relative "rewriter/sql_repair"
