# frozen_string_literal: true

module RailsAgentConsole
  module ConsoleInstaller
    class << self
      def install!(names = RailsAgentConsole.configuration.console_helpers)
        helpers = ConsoleMethods.installable(names)

        if rails_console_methods?
          ::Rails::ConsoleMethods.include(helpers)
        elsif irb_helper_methods?
          register_irb_helpers(helpers)
        else
          ::TOPLEVEL_BINDING.receiver.extend(helpers)
        end

        helpers
      end

      private

      def rails_console_methods?
        defined?(::Rails::ConsoleMethods)
      end

      def irb_helper_methods?
        defined?(::IRB::HelperMethod) && ::IRB::HelperMethod.respond_to?(:register)
      end

      def register_irb_helpers(helpers)
        receiver = Object.new.extend(helpers)

        helpers.instance_methods(false).each do |name|
          ::IRB::HelperMethod.register(name, helper_class_for(name, receiver))
        end
      end

      def helper_class_for(name, receiver)
        Class.new(::IRB::HelperMethod::Base) do
          description "rails_agent_console: #{name}"

          define_method(:execute) do |*args, **options, &block|
            receiver.public_send(name, *args, **options, &block)
          end
        end
      end
    end
  end
end
