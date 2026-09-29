# frozen_string_literal: true

RSpec.describe RailsAgentConsole::ValueCheck do
  def note_for(code)
    RailsAgentConsole::Executor.run(code).note
  end

  it "names the values a column holds when the query asks for one it never holds" do
    expect(note_for('Customer.where(country: "Croatia")'))
      .to eq('customers.country never holds "Croatia". The values it holds are: HR, DE.')
  end

  it "checks conditions on a joined table and behind an aggregate" do
    expect(note_for('Invoice.joins(:customer).where(customers: { country: "Croatia" }).count'))
      .to include('customers.country never holds "Croatia"')
  end

  it "checks a query that ends in pluck with nested parentheses" do
    expect(note_for('Customer.where(country: "Croatia").pluck(Arel.sql("LOWER(name)"))'))
      .to include('never holds "Croatia"')
  end

  it "checks a query whose SQL join has an equals sign" do
    code = 'Invoice.joins("INNER JOIN customers ON customers.id = invoices.customer_id")' \
           '.where(customers: { country: "Croatia" }).count'

    expect(note_for(code)).to include('never holds "Croatia"')
  end

  it "checks where.not, which would otherwise quietly keep every row" do
    expect(note_for('Customer.where.not(country: "Croatia").count')).to include("HR, DE")
  end

  it "points at a value that differs only in capitals" do
    expect(note_for('Customer.where(country: ["hr", "DE"])'))
      .to eq('customers.country never holds "hr". It holds "HR", with different capitals.')
  end

  it "says nothing when the value exists, or for a write" do
    expect(note_for('Customer.where(country: "HR")')).to be_nil
    expect(note_for('Customer.where(plan: "free").order(:name).pluck(:name)')).to be_nil
    expect(note_for('Customer.create!(name: "Split Labs", country: "Croatia")')).to be_nil
    expect(described_class.notes(Customer.all)).to eq([])
  end
end
