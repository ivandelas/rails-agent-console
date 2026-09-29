# frozen_string_literal: true

RSpec.describe RailsAgentConsole::Executor do
  describe ".run" do
    it "returns the value of the expression" do
      outcome = described_class.run("Customer.count")

      expect(outcome).to be_ok
      expect(outcome.value).to eq(2)
      expect(outcome.duration).to be >= 0
    end

    it "captures errors instead of raising" do
      outcome = described_class.run("Customer.where(nope: 1).count")

      expect(outcome).not_to be_ok
      expect(outcome.error).to be_a(Exception)
    end

    it "captures exceptions that are not StandardError" do
      outcome = described_class.run("raise NotImplementedError")

      expect(outcome).not_to be_ok
    end

    it "cannot see the locals of the caller" do
      secret = "do not touch"

      outcome = described_class.run("secret")

      expect(outcome).not_to be_ok, "the sandbox read #{secret}"
      expect(outcome.error).to be_a(NameError)
    end

    it "keeps its own locals between runs" do
      described_class.run("cached_total = Customer.count")

      expect(described_class.run("cached_total").value).to eq(2)
    end

    it "forgets them after a reset" do
      described_class.run("cached_total = Customer.count")
      described_class.reset!

      expect(described_class.run("cached_total")).not_to be_ok
    end

    it "enforces the timeout" do
      RailsAgentConsole.configuration.execution_timeout = 1

      outcome = described_class.run("sleep 5")

      expect(outcome.error).to be_a(Timeout::Error)
    end

    it "runs without a timeout when it is disabled" do
      RailsAgentConsole.configuration.execution_timeout = nil

      expect(described_class.run("Customer.count")).to be_ok
    end
  end

  describe ".run on a relation that only fails once it is loaded" do
    it "reports the failure as this query's failure" do
      outcome = described_class.run("Customer.joins(:page_views)")

      expect(outcome).not_to be_ok
      expect(outcome.error).to be_a(ActiveRecord::ConfigurationError)
    end

    it "hands back a relation that is already loaded" do
      outcome = described_class.run("Customer.where(plan: \"free\")")

      expect(outcome.value).to be_loaded
      expect(described_class.describe(outcome.value)).to eq("1 record")
    end

    it "describes a broken result instead of raising" do
      expect(described_class.describe(Customer.joins(:page_views))).to eq("ActiveRecord::Relation")
    end
  end

  describe ".run on a query with no aggregate after group" do
    it "answers with the counts per group" do
      outcome = described_class.run("Customer.group(:country)")

      expect(outcome).to be_ok
      expect(outcome.value).to eq({ "HR" => 1, "DE" => 1 })
      expect(outcome.note).to match(/no aggregate after `group`/)
      expect(described_class.describe(outcome.value)).to eq("2 groups")
    end

    it "says nothing about queries that do aggregate" do
      outcome = described_class.run("Customer.group(:country).count")

      expect(outcome.value).to eq({ "HR" => 1, "DE" => 1 })
      expect(outcome.note).to be_nil
    end

    it "leaves an ungrouped relation alone" do
      outcome = described_class.run("Customer.where(plan: \"free\")")

      expect(described_class).to be_relation(outcome.value)
      expect(outcome.note).to be_nil
    end

    it "shows a grouped relation that selects its own aggregate as its selected values" do
      outcome = described_class.run(
        "Customer.group(:country).select(Arel.sql(\"country, COUNT(*) AS total\")).order(:country)"
      )

      expect(outcome.value).to all(include("country", "total"))
      expect(outcome.value.first).not_to have_key("id")
      expect(outcome.note).to match(/Grouped rows have no id/)
    end

    it "shows whole-number group keys, such as a month from EXTRACT, as integers" do
      outcome = described_class.run('{ [BigDecimal("2025"), BigDecimal("3")] => 4, BigDecimal("1.5") => 2 }')

      expect(outcome.value).to eq([2025, 3] => 4, BigDecimal("1.5") => 2)
      expect(outcome.value.keys.first).to all(be_an(Integer))
    end

    it "keeps records when a grouped relation selects whole rows" do
      outcome = described_class.run('Customer.joins(:invoices).group("customers.id").select("customers.*")')

      expect(outcome.value.first).to be_a(Customer)
      expect(outcome.note).to be_nil
    end

    it "shows whole rows with a computed column as values, so the column is not hidden" do
      outcome = described_class.run(
        'Customer.joins(:invoices).group("customers.id").select("customers.*, COUNT(invoices.id) AS invoice_count")'
      )

      expect(outcome.value).to all(include("id", "name", "invoice_count"))
      expect(outcome.note).to match(/computed columns/)
    end
  end

  describe ".preflight_count" do
    {
      "Customer.all" => 2,
      "Customer.where(plan: \"free\")" => 1,
      "Invoice.where(status: \"unpaid\")" => 2,
      "Customer.joins(:invoices).distinct" => 2,
      "Customer.select(:id, :name)" => 2,
      "Customer.where(plan: \"free\").select(:id, :name, :country)" => 1
    }.each do |code, expected|
      it "counts #{code} as #{expected}" do
        expect(described_class.preflight_count(code)).to eq(expected)
      end
    end

    [
      "Customer.count",
      "Invoice.sum(:amount)",
      "Customer.pluck(:name)",
      "Customer.exists?",
      "Invoice.group(:status).sum(Arel.sql(\"amount\"))",
      "Invoice.group(:status).count"
    ].each do |code|
      it "skips the aggregate #{code}" do
        expect(described_class.preflight_count(code)).to be_nil
      end
    end

    it "can be switched off" do
      RailsAgentConsole.configuration.preflight_count = false

      expect(described_class.preflight_count("Customer.all")).to be_nil
    end

    it "never runs anything that is not read-only" do
      expect(described_class.preflight_count("Customer.all.delete_all")).to be_nil
      expect(Customer.count).to eq(2)
    end

    it "returns nil when the query is broken" do
      expect(described_class.preflight_count("Customer.where(nope: 1)")).to be_nil
    end
  end

  describe ".impact_estimate" do
    {
      "Customer.where(plan: \"free\").delete_all" => 1,
      "Customer.all.delete_all" => 2,
      "Invoice.all.update_all(status: \"void\")" => 3,
      "Invoice.where(status: \"unpaid\").destroy_all" => 2,
      "Customer.first.destroy" => nil
    }.each do |code, expected|
      it "estimates #{code} as #{expected.inspect}" do
        expect(described_class.impact_estimate(code)).to eq(expected)
      end
    end

    it "is nil when there is no destructive tail" do
      expect(described_class.impact_estimate("Customer.count")).to be_nil
    end

    it "does not change any data while estimating" do
      described_class.impact_estimate("Customer.all.delete_all")

      expect(Customer.count).to eq(2)
    end
  end

  describe ".describe" do
    it "summarises a relation" do
      expect(described_class.describe(Customer.all)).to eq("2 records")
      expect(described_class.describe(Customer.where(plan: "free"))).to eq("1 record")
    end

    it "summarises a grouped relation as groups" do
      expect(described_class.describe(Customer.group(:country))).to eq("2 groups")
      expect(described_class.describe(Customer.where(plan: "free").group(:country))).to eq("1 group")
    end

    it "summarises the top-groups idiom from the prompt" do
      outcome = described_class.run("Customer.group(:country).order(Arel.sql(\"COUNT(*) DESC\")).limit(5).count")

      expect(outcome).to be_ok
      expect(described_class.describe(outcome.value)).to eq("2 groups")
    end

    it "summarises a grouped relation the agent would actually run" do
      outcome = described_class.run("Customer.where(plan: %w[free enterprise]).group(:country)")

      expect(described_class.describe(outcome.value)).to eq("2 groups")
    end

    it "summarises arrays, hashes and scalars" do
      expect(described_class.describe(%w[a b])).to eq("2 items")
      expect(described_class.describe(["a"])).to eq("1 item")
      expect(described_class.describe({ "HR" => 1 })).to eq("1 group")
      expect(described_class.describe({ "HR" => 1, "DE" => 2 })).to eq("2 groups")
      expect(described_class.describe(42)).to eq("42")
      expect(described_class.describe(nil)).to eq("nil")
      expect(described_class.describe("text")).to eq("\"text\"")
    end

    it "truncates very long inspects" do
      RailsAgentConsole.configuration.inspect_limit = 1

      expect(described_class.describe("x" * 500)).to end_with("...")
    end
  end
end
