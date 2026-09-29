# frozen_string_literal: true

require_relative "lib/rails_agent_console/version"

Gem::Specification.new do |spec|
  spec.name = "rails_agent_console"
  spec.version = RailsAgentConsole::VERSION
  spec.authors = ["Ivan Blažević"]
  spec.email = ["ivan.blazevic@rubycode.co"]

  spec.summary = "Plain-English questions in rails console, answered with ActiveRecord you read before it runs."
  spec.description = <<~DESC
    rails_agent_console adds `ai`, `ai!`, `ask` and `explain` to the Rails console you already use.
    It describes your real schema (models, columns, associations) to an LLM, gets back one
    ActiveRecord query, checks it call by call against a read-only allowlist, fixes the model's
    common mistakes in code, and runs it only after you confirm. Works with OpenAI, Anthropic,
    Gemini, Ollama or any OpenAI-compatible endpoint, at about 1,700 tokens per question.
  DESC
  spec.homepage = "https://github.com/blaz1988/rails-agent-console"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["documentation_uri"] = "#{spec.homepage}#readme"
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md", "CHANGELOG.md", "LICENSE.txt"]
  spec.bindir = "exe"
  spec.executables = ["rails-agent"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 7.0", "< 9"
  spec.add_dependency "railties", ">= 7.0", "< 9"
end
