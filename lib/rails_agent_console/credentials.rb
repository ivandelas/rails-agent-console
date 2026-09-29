# frozen_string_literal: true

require "yaml"
require "fileutils"

module RailsAgentConsole
  # ~/.rails_agent_console/config (0600, inside a 0700 directory):
  #
  #     default_provider: openai
  #     openai:
  #       api_key: sk-...
  #       model: gpt-4o-mini
  module Credentials
    DIRECTORY = File.join(Dir.home, ".rails_agent_console")
    PATH = File.join(DIRECTORY, "config")

    class << self
      def path
        ENV.fetch("RAILS_AGENT_CONSOLE_CONFIG", PATH)
      end

      def exist?
        File.exist?(path)
      end

      def read
        return {} unless exist?

        data = YAML.safe_load_file(path) || {}
        data.is_a?(Hash) ? data : {}
      rescue StandardError
        {}
      end

      def store(provider:, api_key: nil, model: nil, base_url: :keep)
        data = read
        data["default_provider"] = provider.to_s
        entry = data[provider.to_s].is_a?(Hash) ? data[provider.to_s] : {}
        entry["api_key"] = api_key if api_key
        entry["model"] = model if model
        store_base_url(entry, base_url)
        data[provider.to_s] = entry
        write(data)
      end

      def store_base_url(entry, base_url)
        return if base_url == :keep

        base_url.to_s.strip.empty? ? entry.delete("base_url") : entry["base_url"] = base_url
      end

      def write(data)
        directory = File.dirname(path)
        FileUtils.mkdir_p(directory)
        File.chmod(0o700, directory) if File.owned?(directory) && directory == DIRECTORY
        File.write(path, YAML.dump(data))
        File.chmod(0o600, path)
        path
      end

      def delete!
        FileUtils.rm_f(path)
      end
    end
  end
end
