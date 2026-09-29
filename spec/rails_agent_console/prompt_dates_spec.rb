# frozen_string_literal: true

RSpec.describe RailsAgentConsole::Prompt::Dates do
  def annotate(prompt)
    described_class.annotate(prompt)
  end

  it "spells out a year as the range to filter on" do
    expect(annotate("find customers from 2025"))
      .to end_with('Dates in this request, as ranges to filter on: 2025 is Time.zone.parse("2025-01-01").all_year.')
  end

  it "spells out a month of a year" do
    annotated = annotate("invoices paid in March 2024")

    expect(annotated).to include('March 2024 is Time.zone.parse("2024-03-01").all_month')
    expect(annotated).not_to include("all_year")
  end

  it "lists every year once" do
    expect(annotate("customers from 2024 who bought again in 2025 or 2024").scan("all_year").size).to eq(2)
  end

  {
    "a request without a date" => "how many customers are there",
    "a number that is not a year" => "customers with more than 2500 points",
    "an amount with decimals" => "invoices over 2025.50",
    "a full date" => "searches on 2025-03-01"
  }.each do |label, prompt|
    it "leaves #{label} alone" do
      expect(annotate(prompt)).to eq(prompt)
    end
  end

  it "is what the model is asked" do
    stub_client(json_reply("Customer.count"))
    answer_with("y")

    RailsAgentConsole.agent.run("customers from 2025")

    expect(last_request[:messages].last[:content]).to include('2025 is Time.zone.parse("2025-01-01").all_year')
  end

  it "gives a range the validator accepts and the database runs" do
    code = 'Customer.where(created_at: Time.zone.parse("2025-01-01").all_year).count'

    expect(RailsAgentConsole::QueryValidator.validate(code)).to be_valid
    Time.use_zone("UTC") { expect(RailsAgentConsole::Executor.run(code)).to be_ok }
  end
end
