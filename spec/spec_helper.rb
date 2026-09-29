# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "rails_agent_console"
require "stringio"
require "tmpdir"
require "fileutils"

require_relative "support/test_app"
require_relative "support/console_output"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.order = :random
  config.warnings = false
  Kernel.srand config.seed

  config.include ConsoleOutput

  config.around do |example|
    previous = ENV.fetch("RAILS_AGENT_CONSOLE_CONFIG", nil)
    Dir.mktmpdir do |dir|
      ENV["RAILS_AGENT_CONSOLE_CONFIG"] = File.join(dir, "config")
      example.run
    ensure
      ENV["RAILS_AGENT_CONSOLE_CONFIG"] = previous
    end
  end

  config.before do
    RailsAgentConsole.reset!
    RailsAgentConsole::Executor.reset!
    reset_console_io
    TestApp.reseed!
  end

  config.after do
    RailsAgentConsole.reset!
  end
end
