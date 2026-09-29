# frozen_string_literal: true

RSpec.describe RailsAgentConsole::History do
  subject(:history) { described_class.new }

  it "replays turns as a user/assistant transcript" do
    history.add(prompt: "count customers", code: "Customer.count", explanation: "counts", outcome: "2")

    messages = history.messages

    expect(messages.size).to eq(2)
    expect(messages.first).to eq(role: "user", content: "count customers")
    payload = JSON.parse(messages.last[:content])
    expect(payload).to include("code" => "Customer.count", "explanation" => "counts", "result" => "2")
  end

  it "omits absent details" do
    history.add(prompt: "q", code: "Customer.count")

    expect(JSON.parse(history.messages.last[:content]).keys).to eq(%w[code])
  end

  [1, 2, 6].each do |limit|
    it "keeps at most #{limit} turns" do
      RailsAgentConsole.configuration.max_history = limit
      10.times { |i| history.add(prompt: "q#{i}", code: "Customer.limit(#{i})") }

      expect(history.turns.size).to eq(limit)
      expect(history.turns.last.prompt).to eq("q9")
    end
  end

  it "takes an explicit limit" do
    limited = described_class.new(limit: 1)
    limited.add(prompt: "a", code: "Customer.count")
    limited.add(prompt: "b", code: "Customer.count")

    expect(limited.turns.map(&:prompt)).to eq(%w[b])
  end

  it "exposes the last turn" do
    history.add(prompt: "a", code: "Customer.count")
    history.add(prompt: "b", code: "Customer.all")

    expect(history.last.prompt).to eq("b")
  end

  it "does not leak its internal array" do
    history.add(prompt: "a", code: "Customer.count")
    history.turns.clear

    expect(history.turns.size).to eq(1)
  end

  it "clears" do
    history.add(prompt: "q", code: "Customer.count")

    expect(history.clear).to be_empty
    expect(history.to_s).to eq("(no queries yet)")
  end

  it "prints a numbered summary" do
    history.add(prompt: "count them", code: "Customer.count")

    expect(history.to_s).to eq("1. count them\n   Customer.count")
  end
end
