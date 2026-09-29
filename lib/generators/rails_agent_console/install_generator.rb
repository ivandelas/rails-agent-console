# frozen_string_literal: true

require "rails/generators/base"

module RailsAgentConsole
  module Generators
    class InstallGenerator < ::Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates config/initializers/rails_agent_console.rb"

      def create_initializer
        template "rails_agent_console.rb", "config/initializers/rails_agent_console.rb"
      end
    end
  end
end
