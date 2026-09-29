# frozen_string_literal: true

require "timeout"

module RailsAgentConsole
  module Executor
    AGGREGATES = %w[count sum average minimum maximum size length pluck ids exists? any? empty? tally].freeze
    DESTRUCTIVE_TAIL = /\.\s*(delete_all|destroy_all|update_all|delete|destroy)\s*(\([^()]*\))?\s*\z/m
    ASSIGNMENT = /(?<![=!<>])=(?![=~>])/
    NO_AGGREGATE_NOTE = "The query had no aggregate after `group`, so the groups were counted."
    GROUPED_ROWS_NOTE = "Grouped rows have no id, so each one is shown as its selected values."
    COMPUTED_NOTE = "The rows carry computed columns a record would hide, so each one is shown as its values."

    Outcome = Struct.new(:value, :error, :duration, :note, keyword_init: true) do
      def ok?
        error.nil?
      end
    end

    class << self
      def run(code)
        started = now
        raw = with_timeout { evaluate(code) }
        value, note = resolve(raw)
        duration = now - started
        notes = [note, *value_notes(code, raw)].compact
        Outcome.new(value: value, error: nil, duration: duration, note: notes.empty? ? nil : notes.join("\n"))
      rescue Exception => e # rubocop:disable Lint/RescueException
        Outcome.new(value: nil, error: e, duration: now - started)
      end

      def preflight_count(code)
        return unless RailsAgentConsole.configuration.preflight_count
        return if aggregate?(code)

        count_rows(code)
      end

      def impact_estimate(code)
        stripped = code.sub(DESTRUCTIVE_TAIL, "")
        return if stripped == code || stripped.strip.empty?

        count_rows(stripped)
      end

      def describe(value)
        limit = RailsAgentConsole.configuration.inspect_limit

        case value
        when ->(v) { relation?(v) } then describe_relation(value)
        when Array then pluralize(value.size, "item")
        when Hash then pluralize(value.size, "group")
        when nil then "nil"
        else truncate(value.inspect, limit * 20)
        end
      rescue StandardError
        value.class.name.to_s
      end

      def relation?(value)
        defined?(ActiveRecord::Relation) && value.is_a?(ActiveRecord::Relation)
      end

      def sandbox_binding
        @sandbox_binding ||= Object.new.instance_eval { binding }
      end

      def reset!
        @sandbox_binding = nil
      end

      private

      def count_rows(code)
        counting = "(#{code}).count(:all)"
        return unless QueryValidator.validate(counting, write_mode: false).valid?

        value = with_timeout { evaluate(counting) }
        value if value.is_a?(Integer)
      rescue Exception # rubocop:disable Lint/RescueException
        nil
      end

      def resolve(value)
        return [readable_keys(value), nil] if value.is_a?(Hash)
        return [value, nil] unless relation?(value) && !value.loaded?
        return [readable_keys(value.count), NO_AGGREGATE_NOTE] if bare_group?(value)
        return [value.load, nil] unless grouped_select?(value)

        rows = value.to_a
        return [value, nil] if rows.empty?
        return [rows.map { |row| grouped_row(row) }, GROUPED_ROWS_NOTE] if rows.all? { |row| row.id.nil? }
        return [rows.map { |row| grouped_row(row) }, COMPUTED_NOTE] if computed_columns?(value, rows)

        [value, nil]
      end

      def computed_columns?(relation, rows)
        (rows.first.attributes.keys - relation.klass.column_names).any?
      end

      def value_notes(code, raw)
        relation = raw if relation?(raw)
        base = Prompt::FollowUp.base_of(code)
        relation ||= evaluate(base) if base && base != code.strip && !assigns?(code)
        relation?(relation) ? ValueCheck.notes(relation) : []
      rescue StandardError
        []
      end

      def assigns?(code)
        code.gsub(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/, "''").match?(ASSIGNMENT)
      end

      def grouped_row(row)
        row.attributes.compact.transform_values do |value|
          value.is_a?(BigDecimal) && !value.frac.zero? ? value.to_f : whole(value)
        end
      end

      def readable_keys(hash)
        return hash unless hash.keys.flatten.any?(BigDecimal)

        hash.transform_keys { |key| key.is_a?(Array) ? key.map { |part| whole(part) } : whole(key) }
      end

      def whole(value)
        value.is_a?(BigDecimal) && value.frac.zero? ? value.to_i : value
      end

      def bare_group?(value)
        value.group_values.any? && value.select_values.empty?
      end

      def grouped_select?(value)
        value.group_values.any? && value.select_values.any?
      end

      def describe_relation(relation)
        size = relation.size
        size.is_a?(Hash) ? pluralize(size.size, "group") : pluralize(size, "record")
      end

      def evaluate(code)
        eval(code, sandbox_binding, "(rails-agent)", 1) # rubocop:disable Security/Eval
      end

      def aggregate?(code)
        AGGREGATES.include?(trailing_method(code).to_s)
      end

      def trailing_method(code)
        source = code.strip
        source = strip_trailing_arguments(source) if source.end_with?(")")
        source[/([a-z_]\w*[?!]?)\s*\z/, 1]
      end

      def strip_trailing_arguments(source)
        depth = 0
        source.length.downto(1) do |index|
          case source[index - 1]
          when ")" then depth += 1
          when "(" then depth -= 1
          end
          return source[0, index - 1] if depth.zero?
        end
        source
      end

      def with_timeout(&block)
        seconds = RailsAgentConsole.configuration.execution_timeout
        return block.call if seconds.nil? || seconds.to_i <= 0

        Timeout.timeout(seconds.to_i, &block)
      end

      def pluralize(count, noun)
        "#{count} #{count == 1 ? noun : "#{noun}s"}"
      end

      def truncate(string, length)
        string.length > length ? "#{string[0, length]}..." : string
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
