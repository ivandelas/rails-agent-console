# frozen_string_literal: true

RSpec.describe RailsAgentConsole::Proposal do
  describe ".parse" do
    it "reads a plain JSON answer" do
      proposal = described_class.parse(json_reply("Customer.count", explanation: "counts customers"))

      expect(proposal.code).to eq("Customer.count")
      expect(proposal.explanation).to eq("counts customers")
      expect(proposal).to be_safe
    end

    it "reads JSON wrapped in fences and prose" do
      raw = <<~TEXT
        Sure! Here you go:
        ```json
        {"code": "Customer.where(country: \\"HR\\").count", "explanation": "Croatian customers"}
        ```
        Hope that helps.
      TEXT

      proposal = described_class.parse(raw)

      expect(proposal.code).to eq('Customer.where(country: "HR").count')
      expect(proposal.explanation).to eq("Croatian customers")
    end

    it "reads JSON containing braces inside strings" do
      raw = JSON.generate("code" => "Customer.where(plan: \"{free}\").count", "explanation" => "odd data")

      expect(described_class.parse(raw).code).to eq("Customer.where(plan: \"{free}\").count")
    end

    describe "declines dressed up as queries" do
      ["Customer.none", "Customer::Scoped.none", "{}", "[]", "nil", "N/A", "0"].each do |code|
        it "reads #{code} as no query" do
          expect(described_class.parse(json_reply(code))).to be_empty
        end
      end

      ["Customer.where(plan: \"free\").none.count", "Customer.none?", "Customer.count"].each do |code|
        it "reads #{code} as a real query" do
          expect(described_class.parse(json_reply(code))).not_to be_empty
        end
      end
    end

    describe "trimming no-op tails" do
      {
        "Customer.where(created_at: Date.new(2025)..).load" => "Customer.where(created_at: Date.new(2025)..)",
        "Customer.where(country: \"HR\").all" => "Customer.where(country: \"HR\")",
        "Customer.where(country: \"HR\").all.load" => "Customer.where(country: \"HR\")",
        "Customer.first.invoices.load" => "Customer.first.invoices",
        "Customer.all" => "Customer.all",
        "Customer.all.load" => "Customer.all",
        "Customer.all.load.map(&:name)" => "Customer.all.load.map(&:name)",
        "Customer.pluck(:country).all?" => "Customer.pluck(:country).all?",
        "Invoice.where(due_date: Date.current.all_month)" => "Invoice.where(due_date: Date.current.all_month)"
      }.each do |raw, expected|
        it "turns #{raw} into #{expected}" do
          expect(described_class.parse(json_reply(raw)).code).to eq(expected)
        end
      end

      it "leaves a relation that is still valid Ruby" do
        proposal = described_class.parse(json_reply("Customer.where(country: \"HR\").load"))

        expect(proposal).to be_safe
        expect(RailsAgentConsole::Executor.run(proposal.code).value.size).to eq(1)
      end
    end

    describe "counting a query that selects several columns" do
      {
        "Customer.select(:id, :name).count" => "Customer.select(:id, :name).count(:all)",
        "Customer.select(\"country, COUNT(*) AS total\").group(:country).count" =>
          "Customer.select(\"country, COUNT(*) AS total\").group(:country).count(:all)",
        "Customer.select(:plan).count" => "Customer.select(:plan).count",
        "Customer.select(\"COALESCE(plan, 'none')\").count" => "Customer.select(\"COALESCE(plan, 'none')\").count",
        "Customer.select(Arel.sql(\"plan, COUNT(*)\")).group(:plan).count" =>
          "Customer.select(Arel.sql(\"plan, COUNT(*)\")).group(:plan).count(:all)",
        "Customer.select(:plan).where(plan: \"pro\", country: \"HR\").count" =>
          "Customer.select(:plan).where(plan: \"pro\", country: \"HR\").count",
        "Customer.select(:id, :name).count(:all)" => "Customer.select(:id, :name).count(:all)",
        "Customer.select(:id, :name).group(:plan).count.size" => "Customer.select(:id, :name).group(:plan).count.size"
      }.each do |raw, expected|
        it "turns #{raw} into #{expected}" do
          expect(described_class.parse(json_reply(raw)).code).to eq(expected)
        end
      end
    end

    describe "answers that are not quite the contract" do
      it "salvages the code from JSON that does not parse" do
        raw = <<~JSON
          ```json
          {
            "code": "Customer.where(country: \\"HR\\").count",
            "explanation": "Croatian customers.",
            "assumptions": ["country" holds an ISO code]
          }
          ```
        JSON

        proposal = described_class.parse(raw)

        expect(proposal.code).to eq('Customer.where(country: "HR").count')
        expect(proposal.explanation).to eq("Croatian customers.")
      end

      it "unwraps code that arrives as markdown inside the JSON" do
        raw = JSON.generate("code" => "```ruby\nCustomer.count\n```", "explanation" => "all of them")

        expect(described_class.parse(raw).code).to eq("Customer.count")
      end

      it "drops stray backticks around the code" do
        expect(described_class.parse(json_reply("`Customer.count`")).code).to eq("Customer.count")
      end

      it "reads a fenced answer that names a language" do
        expect(described_class.parse("```sql\nCustomer.count\n```").code).to eq("Customer.count")
      end
    end

    it "reads multi-line code" do
      code = "Customer.joins(:invoices)\n        .group(:name)\n        .count"

      expect(described_class.parse(json_reply(code)).code).to eq(code)
    end

    it "falls back to a fenced ruby block" do
      proposal = described_class.parse("Here:\n```ruby\nCustomer.limit(5)\n```")

      expect(proposal.code).to eq("Customer.limit(5)")
      expect(proposal).to be_safe
    end

    it "falls back to a bare expression" do
      expect(described_class.parse("Customer.count").code).to eq("Customer.count")
    end

    it "ignores JSON that carries no code key" do
      expect(described_class.parse('{"answer": "42"}').code).to eq('{"answer": "42"}')
    end

    it "carries assumptions" do
      raw = JSON.generate("code" => "Customer.count", "assumptions" => ["all customers count"])

      expect(described_class.parse(raw).assumptions).to eq(["all customers count"])
    end

    it "is empty when there is nothing to run" do
      expect(described_class.parse("")).to be_empty
      expect(described_class.parse(JSON.generate("code" => "  "))).to be_empty
    end

    ["nil", "NULL", "none", "n/a", "# nothing to do", "# one\n\n# two\n"].each do |placeholder|
      it "treats #{placeholder.strip.inspect} as no code" do
        expect(described_class.parse(JSON.generate("code" => placeholder))).to be_empty
      end
    end

    it "keeps real code that merely starts with a comment" do
      raw = JSON.generate("code" => "# count them\nCustomer.count")

      expect(described_class.parse(raw)).not_to be_empty
    end
  end

  describe "validation" do
    it "marks a write as unsafe in read-only mode" do
      proposal = described_class.parse(json_reply("Customer.delete_all"))

      expect(proposal).not_to be_safe
      expect(proposal).to be_writes
      expect(proposal.violations.join).to include("read-only")
    end

    it "marks the same code safe but destructive in write mode" do
      proposal = described_class.parse(json_reply("Customer.where(plan: \"free\").delete_all"), write_mode: true)

      expect(proposal).to be_safe
      expect(proposal).to be_destructive
    end

    it "reports the models involved" do
      proposal = described_class.parse(json_reply("Customer.joins(:invoices).count"))

      expect(proposal.models).to eq(%w[Customer])
    end
  end
end
