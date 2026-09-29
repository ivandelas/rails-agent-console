# frozen_string_literal: true

module RailsAgentConsole
  module Rewriter
    module Distinct
      SINGLE_ROW = %i[belongs_to has_one].freeze
      NOTE = "`distinct` changes nothing when every join is a belongs_to, and PostgreSQL refuses it " \
             "next to an order by a joined column, so it is left out."

      module_function

      def drop(chain)
        model = Schema.find(chain.receiver)
        index = chain.calls.index { |call| call.text.match?(/\A\.\s*distinct\s*\z/) }
        return if model.nil? || index.nil?
        return unless foreign_order?(chain, model) && single_row_joins?(chain, model)

        [chain.with_calls(chain.calls.reject.with_index { |_, position| position == index }), NOTE]
      end

      def foreign_order?(chain, model)
        chain.calls.any? do |call|
          %w[order reorder].include?(call.name) &&
            call.text.scan(/(\w+)\./).flatten.any? { |table| ![model.table, "Arel"].include?(table) }
        end
      end

      def single_row_joins?(chain, model)
        joins = chain.calls.select { |call| JOINS.key?(call.name) }
        joins.any? && joins.all? do |call|
          names = call.symbol_arguments
          names&.all? { |name| SINGLE_ROW.include?(macro(model, name)) }
        end
      end

      def macro(model, name)
        model.associations.find { |association| association[:name].to_s == name }&.dig(:macro)
      end
    end
  end
end
