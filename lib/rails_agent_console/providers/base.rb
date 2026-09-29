# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module RailsAgentConsole
  module Providers
    class Base
      attr_reader :config

      def initialize(config = RailsAgentConsole.configuration)
        @config = config
      end

      def chat(system:, messages:)
        response = post(endpoint, headers, payload(system: system, messages: messages))
        extract(response)
      end

      def name
        self.class.name.split("::").last
      end

      def model
        config.model
      end

      def models
        []
      end

      def default_base
        self.class::DEFAULT_BASE
      end

      private

      def get(uri, headers = {})
        uri = URI(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 5
        http.read_timeout = 10
        response = http.request(Net::HTTP::Get.new(uri.request_uri, headers))
        JSON.parse(response.body) if response.is_a?(Net::HTTPSuccess)
      rescue StandardError
        nil
      end

      def endpoint
        raise NotImplementedError
      end

      def headers
        { "Content-Type" => "application/json" }
      end

      def payload(system:, messages:)
        raise NotImplementedError
      end

      def extract(_response)
        raise NotImplementedError
      end

      def api_key!
        config.api_key or raise ConfigurationError, "Missing API key for #{config.provider}"
      end

      def post(uri, headers, body)
        uri = URI(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 10
        http.read_timeout = config.request_timeout

        request = Net::HTTP::Post.new(uri.request_uri, headers)
        request.body = JSON.generate(body)

        response = http.request(request)
        handle(response)
      rescue Net::OpenTimeout, Net::ReadTimeout
        raise ProviderError, "#{name} did not respond within #{config.request_timeout}s"
      rescue SocketError, Errno::ECONNREFUSED => e
        raise ProviderError, "Could not reach #{name}: #{e.message}"
      end

      def handle(response)
        body = response.body.to_s
        return JSON.parse(body) if response.is_a?(Net::HTTPSuccess)

        raise ProviderError, "#{name} returned #{response.code}: #{error_message(body)}"
      rescue JSON::ParserError
        raise ProviderError, "#{name} returned a non-JSON response: #{body[0, 200]}"
      end

      def error_message(body)
        parsed = JSON.parse(body)
        return body[0, 200] unless parsed.is_a?(Hash)

        error = parsed["error"]
        message = error.is_a?(Hash) ? error["message"] : error
        (message || parsed["message"] || body[0, 200]).to_s[0, 200]
      rescue JSON::ParserError
        body[0, 200]
      end

      def base_url(default)
        config.api_base || default
      end
    end
  end
end
