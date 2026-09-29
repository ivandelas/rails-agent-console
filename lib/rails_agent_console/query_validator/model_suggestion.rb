# frozen_string_literal: true

module RailsAgentConsole
  class QueryValidator
    module ModelSuggestion
      module_function

      def for(name)
        close = Schema.model_names.select { |model| close?(model.split("::").last.downcase, name.downcase) }
        close.empty? ? "" : " (did you mean #{close.first(3).join(" or ")}?)"
      rescue StandardError
        ""
      end

      def close?(model, wanted)
        single = wanted.singularize
        model.start_with?(single) || model.end_with?(single) || wanted.start_with?(model) ||
          edit_distance(model, wanted) <= 2
      end

      def edit_distance(left, right)
        previous = (0..right.length).to_a
        left.each_char.with_index(1) do |left_char, row|
          current = [row]
          right.each_char.with_index(1) do |right_char, column|
            cost = left_char == right_char ? 0 : 1
            current << [previous[column] + 1, current[column - 1] + 1, previous[column - 1] + cost].min
          end
          previous = current
        end
        previous.last
      end
    end
  end
end
