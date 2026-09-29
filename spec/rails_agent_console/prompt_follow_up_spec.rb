# frozen_string_literal: true

RSpec.describe RailsAgentConsole::Prompt::FollowUp do
  let(:previous) { "Customer.where(created_at: Time.zone.parse('2025-01-01').all_year).count" }

  def annotate(prompt, code = previous)
    described_class.annotate(prompt, code)
  end

  it "hands the previous query, without its aggregate, to a request that refers back to it" do
    expect(annotate("which 3 cities had the most of them?"))
      .to end_with("build on: Customer.where(created_at: Time.zone.parse('2025-01-01').all_year)")
  end

  describe ".for_ask" do
    let(:history) do
      RailsAgentConsole::History.new(limit: 6).add(prompt: "busiest customers", code: "Customer.limit(5)")
    end

    it "hands ask the queries of this session when the question is about them" do
      expect(described_class.for_ask("explain the query you gave me", history))
        .to end_with("oldest first:\n- busiest customers\n  Customer.limit(5)")
    end

    it "leaves a general question, or an empty session, alone" do
      expect(described_class.for_ask("when should I use includes?", history)).to eq("when should I use includes?")
      expect(described_class.for_ask("explain that query", RailsAgentConsole::History.new(limit: 6)))
        .to eq("explain that query")
    end
  end

  it "understands Croatian back-references" do
    expect(annotate("a koliko ih je iz Splita?")).to include("This continues the previous query.")
  end

  {
    "Customer.where(active: true).pluck(:email)" => "Customer.where(active: true)",
    "Customer.group(:city).count(:id)" => "Customer.group(:city)",
    "Customer.order(:created_at).limit(5).to_a" => "Customer.order(:created_at).limit(5)",
    'Customer.limit(5).pluck(Arel.sql("LOWER(name)"), :id)' => "Customer.limit(5)"
  }.each do |code, base|
    it "reads #{code} as #{base}" do
      expect(described_class.base_of(code)).to eq(base)
    end
  end

  it "leaves a request that starts afresh alone" do
    expect(annotate("customers that signed up in 2024")).to eq("customers that signed up in 2024")
  end

  it "leaves the first request of a conversation alone" do
    expect(annotate("group them by city", nil)).to eq("group them by city")
  end

  it "is what the model is asked on a follow-up" do
    stub_client(json_reply(previous), json_reply("Customer.group(:city).count"))
    answer_with("y", "y")

    Time.use_zone("UTC") do
      RailsAgentConsole.agent.run("customers from 2025")
      RailsAgentConsole.agent.run("group them by city")
    end

    expect(llm_requests.last[:messages].last[:content])
      .to include("build on: Customer.where(created_at: Time.zone.parse('2025-01-01').all_year)")
  end
end
