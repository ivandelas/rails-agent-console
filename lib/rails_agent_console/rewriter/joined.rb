# frozen_string_literal: true

module RailsAgentConsole
  module Rewriter
    module Joined
      NESTED = /(\w+):\s*:(\w+)/

      module_function

      def tables(calls, model)
        calls.select { |call| JOINS.key?(call.name) }.each_with_object({}) do |call, tables|
          arguments = call.text[/\((.*)\)\s*\z/m, 1].to_s
          arguments.scan(NESTED).each { |parent, child| add_nested(tables, model, parent, child) }
          arguments.gsub(NESTED, "").gsub(/"[^"]*"|'[^']*'/, "").scan(/:(\w+)/).flatten.each do |name|
            add(tables, model, name)
          end
          call.text.scan(/JOIN\s+"?(\w+)"?/i).flatten.each { |table| tables[table] ||= table }
        end
      end

      def add_nested(tables, model, parent, child)
        through = add(tables, model, parent)
        add(tables, through, child) if through
      end

      def add(tables, model, name)
        target = target(model, name)
        tables[name] = target.table if target
        target
      end

      def target(model, name)
        association = model.associations.find { |candidate| candidate[:name].to_s == name.to_s }
        association && Schema.find(association[:class_name])
      end

      def model_for(table)
        Schema.models.find { |model| model.table == table }
      end
    end
  end
end
