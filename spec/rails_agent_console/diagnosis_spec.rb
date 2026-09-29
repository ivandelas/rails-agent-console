# frozen_string_literal: true

RSpec.describe RailsAgentConsole::Diagnosis do
  describe ".hint" do
    it "recognises a select alias used elsewhere in the query" do
      code = "Customer.select(\"country, COUNT(*) AS total\").group(:country).pluck(:total)"

      expect(described_class.hint(code, 'PG::UndefinedColumn: column "total" does not exist'))
        .to include("`total` is an alias from select(...)")
    end

    it "lists the real columns for a missing column that is not an alias" do
      code = "Customer.where(nickname: \"ivan\")"

      expect(described_class.hint(code, 'column "nickname" does not exist'))
        .to include("customers has no nickname column", "id, name, country, plan")
    end

    it "lists the columns of the table named in a qualified missing column" do
      expect(described_class.hint("Customer.joins(:invoices)", "column invoices.total does not exist"))
        .to include("invoices has no total column", "amount")
    end

    it "points two unassociated models to the column they share" do
      expect(described_class.hint("Invoice.joins(:support_tickets)",
                                  "Can't join 'Invoice' to association named 'support_tickets'"))
        .to include("Invoice and SupportTicket are not associated, but both hold customer_id",
                    "Invoice.where(customer_id: SupportTicket.select(:customer_id))")
    end

    it "explains find with a column name" do
      expect(described_class.hint("Invoice.find(:id)", "Couldn't find Customer with 'id'=id"))
        .to include('find(:id) looks up the literal value "id"')
    end

    it "explains a window function inside an aggregate" do
      expect(described_class.hint("x", "aggregate function calls cannot contain window function calls"))
        .to include("subquery", "Model.from(")
    end

    it "explains a nested aggregate" do
      expect(described_class.hint("SearchResult.group(:x).average(\"COUNT(*)\")",
                                  "PG::GroupingError: aggregate function calls cannot be nested"))
        .to include("Divide two separate aggregates")
    end

    it "explains a column missing from the group by" do
      expect(described_class.hint("Customer.group(:plan).select(:name)",
                                  'column "customers.name" must appear in the GROUP BY clause'))
        .to include("customers.name")
    end

    it "explains a join across an association that does not exist" do
      hint = described_class.hint("Customer.joins(:page_views)",
                                  "Can't join 'Customer' to association named 'page_views'")

      expect(hint).to include("no `page_views` association on Customer",
                              "PageView.joins(:customer)",
                              "Customer.where(id: PageView.select(:customer_id))")
    end

    it "explains a condition on a table the query never joined" do
      expect(described_class.hint("Customer.where(\"invoices.status = 'paid'\")",
                                  'missing FROM-clause entry for table "invoices"'))
        .to include("without that table being in the query")
    end

    it "explains a comparison between two kinds of column" do
      expect(described_class.hint("Customer.where(id: PageView.select(:path))",
                                  "operator does not exist: bigint = character varying"))
        .to include("bigint column is being compared with a character varying one")
    end

    it "explains an alias in a clause that cannot have one" do
      expect(described_class.hint("SearchResult.group(Arel.sql(\"EXTRACT(YEAR FROM created_at) AS year\")).count",
                                  'PG::SyntaxError: syntax error at or near "AS"'))
        .to include("Only a select list may name an alias with AS")
    end

    it "recognises a column that was joined as if it were an association" do
      expect(described_class.hint("Customer.joins(:plan)",
                                  "Can't join 'Customer' to association named 'plan'"))
        .to include("`plan` is a column on Customer, not an association",
                    "Customer.where(plan: nil)")
    end

    it "explains a relation method called on the result of a grouped aggregate" do
      expect(described_class.hint("Customer.group(:plan).count.order(:plan)",
                                  "undefined method `order' for {\"pro\"=>2}:Hash"))
        .to include("return a Hash of results", "aggregate last")
    end

    it "explains the same thing when Ruby words the error its newer way" do
      expect(described_class.hint("Customer.group(:plan).count.order(:plan)",
                                  "undefined method 'order' for an instance of Hash"))
        .to include("return a Hash of results")
    end

    it "explains a date column compared with a Ruby boolean" do
      expect(described_class.hint("Customer.where(created_at: Time.current.wday == 0)",
                                  'PG::InvalidDatetimeFormat: invalid input syntax for type timestamp: "f"'))
        .to include('compared with "f"', "EXTRACT(DOW FROM created_at)")
    end

    it "has nothing to add to an error it does not recognise" do
      expect(described_class.hint("Customer.count", "PG::ConnectionBad: could not connect")).to be_nil
    end
  end
end
