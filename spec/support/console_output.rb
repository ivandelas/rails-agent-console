# frozen_string_literal: true

module ConsoleOutput
  def reset_console_io
    @output = StringIO.new
    RailsAgentConsole.configure do |config|
      config.output = @output
      config.input = StringIO.new("")
      config.color = false
      config.banner = false
      config.setup_on_boot = false
    end
  end

  def printed
    @output.string
  end

  def reconfigure
    RailsAgentConsole.reset!
    reset_console_io
    RailsAgentConsole.configure { |config| yield config if block_given? }
  end

  def stub_providers(models: [], answer: "ok")
    RailsAgentConsole::Providers::REGISTRY.each_value do |klass|
      allow_any_instance_of(klass).to receive(:models) { models }
      allow_any_instance_of(klass).to receive(:installed_models) { models } if klass.method_defined?(:installed_models)
      if answer.is_a?(Exception)
        allow_any_instance_of(klass).to receive(:chat).and_raise(answer)
      else
        allow_any_instance_of(klass).to receive(:chat).and_return(answer)
      end
    end
  end

  def answer_with(*lines)
    RailsAgentConsole.configuration.input = StringIO.new("#{lines.join("\n")}\n")
  end

  def stub_client(*replies)
    queue = replies.flatten
    requests = llm_requests
    RailsAgentConsole.configuration.client = lambda do |system:, messages:|
      requests << { system: system, messages: messages }
      queue.size > 1 ? queue.shift : queue.first
    end
  end

  def llm_requests
    @llm_requests ||= []
  end

  def last_request
    llm_requests.last
  end

  def json_reply(code, explanation: "because", assumptions: [])
    JSON.generate("code" => code, "explanation" => explanation, "assumptions" => assumptions)
  end

  def run_agent(prompt, code:, answers: ["y"], write: false)
    stub_client(*Array(code).map { |snippet| json_reply(snippet) })
    answer_with(*answers)
    RailsAgentConsole.agent.run(prompt, write: write)
  end
end
