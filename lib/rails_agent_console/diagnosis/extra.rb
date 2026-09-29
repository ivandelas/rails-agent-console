# frozen_string_literal: true

module RailsAgentConsole
  module Diagnosis
    module Extra
      QUALIFIED_MISSING = /column (\w+)\.(\w+) does not exist/
      BARE_MISSING = /column "(\w+)" does not exist/
      FIND_BY_NAME = /Couldn't find (\w+) with '(\w+)'=([a-z_]\w*)\b/
      WINDOW_IN_AGGREGATE = /aggregate function calls cannot contain window function calls/

      module_function

      def hint(code, message)
        missing_column_hint(code, message) || find_hint(message) || window_hint(message)
      end

      def missing_column_hint(code, message)
        table, column = message.match(QUALIFIED_MISSING)&.captures
        column ||= message[BARE_MISSING, 1]
        model = table ? Schema.models.find { |candidate| candidate.table == table } : receiver(code)
        return unless column && model

        "#{model.table} has no #{column} column. Its columns are " \
          "#{model.column_names.first(30).join(", ")}; use one of them or leave the code empty."
      end

      def shared_column(owner, name)
        source = Schema.find(owner)
        target = Schema.models.find { |model| [name, name.pluralize].include?(model.table) }
        return unless source && target
        return if source.inbound.any? { |reference| reference[:table] == target.table }

        pair = matching_columns(source, target)
        return unless pair

        "#{source.name} and #{target.name} are not associated, but both hold #{pair.last}: " \
          "#{source.name}.where(#{pair.first}: #{target.name}.select(:#{pair.last}))."
      end

      def matching_columns(source, target)
        ignored = %w[id created_at updated_at]
        source.column_names.product(target.column_names).find do |left, right|
          next false if ignored.include?(left) || ignored.include?(right)

          left == right || left.end_with?("_#{right}") || right.end_with?("_#{left}")
        end
      end

      def receiver(code)
        Schema.find(code.to_s[/\A\s*([A-Z]\w*(?:::[A-Z]\w*)*)/, 1].to_s)
      end

      def find_hint(message)
        model, key, value = message.match(FIND_BY_NAME)&.captures
        return unless model

        "find(:#{value}) looks up the literal value #{value.inspect} in #{model}.#{key}. Comparing " \
          "with a column of another table needs a join and SQL, such as " \
          "joins(:association).where(\"table_a.column <> table_b.column\")."
      end

      def window_hint(message)
        return unless WINDOW_IN_AGGREGATE.match?(message)

        "A window function (LAG, ROW_NUMBER) cannot sit inside an aggregate. Compute it in a " \
          "subquery and aggregate the outer query: " \
          "Model.from(Model.select(\"model_table.*, LAG(created_at) OVER (PARTITION BY customer_id " \
          "ORDER BY created_at) AS previous_at\"), :model_table).average(...)."
      end
    end
  end
end
