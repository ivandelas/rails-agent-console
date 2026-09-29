# frozen_string_literal: true

require "ripper"
require "set"

require_relative "query_validator/model_suggestion"
require_relative "query_validator/sensitive_columns"
require_relative "query_validator/rules"

module RailsAgentConsole
  class QueryValidator
    include Rules

    def self.validate(code, write_mode: RailsAgentConsole.configuration.write_mode?)
      new(code, write_mode: write_mode).validate
    end

    def initialize(code, write_mode: false)
      @code = code.to_s
      @write_mode = write_mode
      @violations = []
      @methods = []
      @constants = []
      @writes = []
      @unknown = []
      @unknown_constants = []
      @bare = []
      @blocked = false
      @syntax_error = false
      @locals = Set.new
    end

    def validate
      if @code.strip.empty?
        @violations << "empty code"
        return result
      end

      sexp = Ripper.sexp(@code)
      if sexp.nil?
        @syntax_error = true
        @violations << syntax_violation
        return result
      end

      collect_locals(sexp)
      inspect_node(sexp)
      classify_methods
      check_sensitive_columns
      result
    end

    private

    def syntax_violation
      message = ParseError.message_for(@code)
      message ? "the code is not valid Ruby: #{message}" : "the code is not valid Ruby"
    end

    def result
      Result.new(code: @code, violations: @violations, writes: @writes,
                 methods: @methods, constants: @constants, unknown: @unknown,
                 unknown_constants: @unknown_constants, blocked: @blocked,
                 syntax_error: @syntax_error)
    end

    def collect_locals(node, inside_params: false)
      return unless node.is_a?(Array)

      case node.first
      when :var_field, :params, :block_var, :rest_param, :kwrest_param, :blockarg
        collect_identifiers(node)
        inside_params = true
      end

      node.each { |child| collect_locals(child, inside_params: inside_params) if child.is_a?(Array) }
    end

    def collect_identifiers(node)
      return unless node.is_a?(Array)

      @locals << node[1] if node.first == :@ident && node[1].is_a?(String)
      node.each { |child| collect_identifiers(child) if child.is_a?(Array) }
    end

    def inspect_node(node)
      return unless node.is_a?(Array)
      return if handled_as_data?(node)
      return if handled_as_declaration?(node)
      return if handled_as_call?(node)

      inspect_children(node)
    end

    def handled_as_data?(node)
      case node.first
      when :symbol_literal, :@label
        true
      when :@tstring_content
        check_string(node[1])
        true
      when :@const
        @constants << node[1]
        true
      else
        false
      end
    end

    def handled_as_declaration?(node)
      case node.first
      when :xstring_literal
        block("shell command execution via backticks")
      when :def, :defs, :class, :module, :sclass
        block("defining methods or classes is not allowed in a generated query")
      when :@ivar, :@gvar, :@cvar
        block("access to variable #{node[1]}")
      when :field
        block("attribute assignment")
        inspect_children(node)
      when :super, :zsuper
        block("super")
      else
        return false
      end
      true
    end

    def handled_as_call?(node)
      case node.first
      when :call
        symbol_receiver(node)
        record_message(node[3], receiver: node[1])
        inspect_node(node[1])
      when :command_call
        record_message(node[3], receiver: node[1])
        inspect_node(node[1])
        inspect_node(node[4])
      when :fcall
        record_message(node[1])
      when :command
        record_message(node[1])
        inspect_node(node[2])
      when :vcall
        record_bare(node[1])
      else
        return false
      end
      true
    end

    def symbol_receiver(node)
      return unless node[1].is_a?(Array) && node[1].first == :symbol_literal
      return unless node[3].is_a?(Array) && node[3].first == :@ident
      return if %w[to_s to_sym to_proc].include?(node[3][1])

      name = node[1].flatten.find { |part| part.is_a?(String) }
      violate("`:#{name}.#{node[3][1]}` calls #{node[3][1]} on a Symbol, not on a table. " \
              "A column of a joined table is written in SQL: where(\"#{name.pluralize}.#{node[3][1]} = ...\")")
    end

    def inspect_children(node)
      node.each { |child| inspect_node(child) if child.is_a?(Array) }
    end

    def record_message(message, receiver: nil)
      return @methods << "call" if message == :call
      return unless message.is_a?(Array)

      case message.first
      when :@ident, :@op, :@kw
        @methods << message[1] unless read_on_receiver?(message[1], receiver)
      when :@const then @constants << message[1]
      else inspect_node(message)
      end
    end

    def read_on_receiver?(name, receiver)
      value_construction?(name, receiver) || relation_load?(name, receiver)
    end

    def relation_load?(name, receiver)
      return false unless name == "load" && !receiver.nil?

      constant = constant_name(receiver)
      constant.nil? || !UNSAFE_LOAD_RECEIVERS.include?(constant)
    end

    def value_construction?(name, receiver)
      return false unless CONSTRUCTORS.include?(name)

      constant = constant_name(receiver)
      !constant.nil? && VALUE_CONSTANTS.include?(constant) && !model_constants.include?(constant)
    end

    def constant_name(node)
      return unless node.is_a?(Array)

      case node.first
      when :var_ref, :top_const_ref then constant_name(node[1])
      when :const_path_ref then constant_name(node[2])
      when :@const then node[1]
      end
    end

    def record_bare(message)
      return unless message.is_a?(Array) && message.first == :@ident
      return if @locals.include?(message[1])

      @methods << message[1]
      @bare << message[1]
    end

    def check_string(value)
      block("raw SQL that modifies data: #{value.strip.inspect}") if value.to_s.match?(DANGEROUS_SQL)
    end

    def classify_methods
      @methods.uniq.each do |name|
        if FORBIDDEN.include?(name)
          block("`#{name}` is never allowed from the agent console")
        elsif WRITE.include?(name)
          @writes << name
          violate("`#{name}` writes to the database (read-only mode)") unless @write_mode
        elsif allowed?(name)
          next
        else
          @unknown << name
          violate("`#{name}` is not on the read-only allowlist")
        end
      end

      @constants.uniq.each do |name|
        next if allowed_constant?(name)

        if BLOCKED_CONSTANTS.include?(name)
          block("constant `#{name}` is never allowed from the agent console")
        else
          @unknown_constants << name
          violate("constant `#{name}` is not allowed#{ModelSuggestion.for(name)}")
        end
      end
    end

    def allowed?(name)
      return allowed_bare?(name) if @bare.include?(name)

      ALLOWED.include?(name) || schema_readers.include?(name) ||
        extra_allowed_methods.include?(name) ||
        (name.end_with?("?") && ALLOWED.include?(name.chomp("?")))
    end

    def allowed_bare?(name)
      ALLOWED.include?(name) || extra_allowed_methods.include?(name) ||
        (name.end_with?("?") && ALLOWED.include?(name.chomp("?")))
    end

    def schema_readers
      @schema_readers ||= Set.new(
        Schema.models.flat_map do |model|
          model.column_names + model.column_names.map { |column| "#{column}?" } + model.association_names
        end
      )
    rescue StandardError
      Set.new
    end

    def allowed_constant?(name)
      SAFE_CONSTANTS.include?(name) || model_constants.include?(name) ||
        extra_allowed_constants.include?(name)
    end

    def model_constants
      @model_constants ||= Set.new(Schema.model_names.flat_map { |model| model.split("::") })
    rescue StandardError
      Set.new
    end

    def extra_allowed_methods
      Set.new(RailsAgentConsole.configuration.extra_allowed_methods.map(&:to_s))
    end

    def extra_allowed_constants
      Set.new(RailsAgentConsole.configuration.extra_allowed_constants.map(&:to_s))
    end

    def check_sensitive_columns
      SensitiveColumns.named_in(@code).each do |name|
        block("`#{name}` holds a credential and is never read by the agent")
      end
    end

    def violate(message)
      @violations << message
    end

    def block(message)
      @blocked = true
      violate(message)
    end
  end
end

require_relative "query_validator/parse_error"
require_relative "query_validator/result"
