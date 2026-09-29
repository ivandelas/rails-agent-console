# frozen_string_literal: true

module RailsAgentConsole
  # Spots a condition that compares a column with a value the column never holds,
  # such as country: "Croatia" where the data says "HR". The values it lists are
  # printed in the console only; nothing here is sent to the model.
  module ValueCheck
    MAX_DISTINCT = 30
    SHOWN = 10
    TEXT_TYPES = %i[string text citext].freeze

    module_function

    def notes(relation)
      conditions(relation.where_clause.ast).uniq.filter_map { |table, column, value| note(table, column, value) }
    rescue StandardError
      []
    end

    def conditions(node)
      case node
      when Arel::Nodes::HomogeneousIn
        pairs(node.attribute, node.values)
      when Arel::Nodes::Equality, Arel::Nodes::NotEqual, Arel::Nodes::In, Arel::Nodes::NotIn
        comparison(node)
      when Arel::Nodes::Binary, Arel::Nodes::And, Arel::Nodes::Or, Arel::Nodes::Grouping, Arel::Nodes::Not
        children(node).flat_map { |child| conditions(child) }
      else
        []
      end
    end

    def children(node)
      return node.children if node.respond_to?(:children)
      return [node.expr] if node.respond_to?(:expr)

      [node.left, node.right]
    end

    def comparison(node)
      pairs(node.left, node.right)
    end

    def pairs(attribute, values)
      return [] unless attribute.is_a?(Arel::Attributes::Attribute)

      Array(values).filter_map { |value| literal(value) }
                   .map { |value| [attribute.relation.name.to_s, attribute.name.to_s, value] }
    end

    def literal(node)
      value = node.respond_to?(:value) ? node.value : node
      value = value.value_before_type_cast if value.respond_to?(:value_before_type_cast)
      value if value.is_a?(String) && !value.empty?
    end

    def note(table, column, value)
      klass = model_for(table, column)
      return if klass.nil?

      counts = klass.unscoped.where.not(column => nil).group(column).order(Arel.sql("COUNT(*) DESC"))
                    .limit(MAX_DISTINCT + 1).count
      return if counts.size > MAX_DISTINCT || counts.key?(value)

      "#{table}.#{column} never holds #{value.inspect}. #{listing(counts.keys, value)}"
    end

    def listing(values, wanted)
      close = values.find { |candidate| candidate.to_s.casecmp?(wanted) }
      return "It holds #{close.inspect}, with different capitals." if close

      shown = values.first(SHOWN).join(", ")
      more = values.size > SHOWN ? " (+#{values.size - SHOWN} more)" : ""
      "The values it holds are: #{shown}#{more}."
    end

    def model_for(table, column)
      model = Schema.models.find { |candidate| candidate.table == table }
      return if model.nil?

      type = model.columns.find { |name, _| name == column }&.dig(1)
      Object.const_get(model.name) if TEXT_TYPES.include?(type)
    end
  end
end
