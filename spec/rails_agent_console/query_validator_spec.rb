# frozen_string_literal: true

RSpec.describe RailsAgentConsole::QueryValidator do
  subject(:validator) { described_class }

  def validate(code, write_mode: false)
    described_class.validate(code, write_mode: write_mode)
  end

  READ_ONLY_QUERIES = [
    "Customer.count",
    "Customer.all",
    "Customer.where(created_at: 30.days.ago..).count",
    "Customer.where(created_at: Time.current.beginning_of_month..).group(:country).count",
    "Customer.where(plan: %w[pro enterprise]).order(:name).limit(10).pluck(:name)",
    "Customer.where.not(plan: \"free\").count",
    "Customer.joins(:invoices).where(invoices: { status: \"unpaid\" }).distinct.pluck(:name)",
    "Customer.left_joins(:invoices).group(\"customers.id\").having(\"COUNT(invoices.id) = 0\").count",
    "Customer.includes(:invoices).find_each { |customer| customer.invoices.size }",
    "Customer.joins(:invoices).group(:name).order(Arel.sql(\"SUM(invoices.amount) DESC\")).limit(5).sum(:amount)",
    "Customer.group(:country).order(Arel.sql(\"COUNT(*) DESC\")).limit(5).count",
    "Customer.where(id: Invoice.where(status: \"unpaid\").select(:customer_id)).pluck(:name)",
    "Invoice.where(paid_at: nil).where(due_date: ..Date.current).sum(:amount)",
    "Invoice.group(:status).average(:amount)",
    "Invoice.where(due_date: Date.current.all_month).minimum(:amount)",
    "Invoice.where(created_at: 1.week.ago..Time.current).maximum(:amount)",
    "Customer.find_by(name: \"Acme Corp\")",
    "Customer.exists?(plan: \"free\")",
    "Customer.first.invoices.sum(:amount)",
    "Customer.all.map { |customer| [customer.name, customer.invoices.count] }.sort_by { |_n, c| -c }",
    "Customer.all.group_by(&:country).transform_values(&:size)",
    "SupportTicket.where(resolved_at: nil).joins(:customer).pluck(\"customers.name\", :subject)",
    "Customer.pluck(:country).tally",
    "Invoice.where(status: \"unpaid\").pick(:amount)",
    "Customer.order(created_at: :desc).first(3).map(&:name)",
    "Invoice.sum(:amount).to_f.round(2)",
    "Customer.where(id: rand(1..10)).count",
    "Customer.find_by(name: SecureRandom.hex(4))"
  ].freeze

  WRITE_CALLS = {
    "save" => "Customer.first.save",
    "update" => "Customer.first.update(country: \"HR\")",
    "update_all" => "Customer.all.update_all(country: \"HR\")",
    "update_column" => "Customer.first.update_column(:country, \"HR\")",
    "delete" => "Customer.first.delete",
    "delete_all" => "Customer.where(plan: \"free\").delete_all",
    "delete_by" => "Customer.delete_by(plan: \"free\")",
    "destroy" => "Customer.first.destroy",
    "destroy_all" => "Customer.where(plan: \"free\").destroy_all",
    "create!" => "Customer.create!(name: \"x\")",
    "new" => "Customer.new(name: \"x\")",
    "insert_all" => "Invoice.insert_all([{ customer_id: 1, amount: 1 }])",
    "upsert" => "Invoice.upsert({ id: 1, customer_id: 1, amount: 2 })",
    "touch" => "Customer.first.touch",
    "increment!" => "Invoice.first.increment!(:amount)",
    "find_or_create_by" => "Customer.find_or_create_by(name: \"x\")",
    "transaction" => "Customer.transaction { Customer.count }"
  }.freeze

  ALWAYS_FORBIDDEN = {
    "eval" => "eval(\"Customer.count\")",
    "send" => "Customer.send(:delete_all)",
    "public_send" => "Customer.public_send(:delete_all)",
    "system" => "system(\"rm -rf /tmp/x\")",
    "exec" => "exec(\"ls\")",
    "require" => "require \"open3\"",
    "load" => "load \"/tmp/x.rb\"",
    "exit" => "exit",
    "binding" => "binding",
    "connection" => "Customer.connection.execute(\"SELECT 1\")",
    "find_by_sql" => "Customer.find_by_sql(\"SELECT * FROM customers\")",
    "select_all" => "Customer.select_all(\"SELECT 1\")",
    "drop_table" => "Customer.drop_table(:customers)",
    "define_method" => "Customer.define_method(:boom) { 1 }",
    "instance_variable_get" => "Customer.first.instance_variable_get(:@attributes)",
    "method" => "Customer.method(:delete_all)",
    "backticks" => "`ls`",
    "gets" => "gets"
  }.freeze

  BLOCKED_CONSTANTS = {
    "File" => "File.read(\"/etc/passwd\")",
    "Dir" => "Dir.glob(\"*\")",
    "IO" => "IO.read(\"/etc/passwd\")",
    "Kernel" => "Kernel.puts(\"hi\")",
    "ENV" => "ENV[\"DATABASE_URL\"]",
    "Process" => "Process.pid",
    "Open3" => "Open3.capture2(\"ls\")",
    "Net" => "Net::HTTP.get(\"example.com\", \"/\")",
    "Marshal" => "Marshal.dump(Customer.first)",
    "ObjectSpace" => "ObjectSpace.count_objects"
  }.freeze

  describe "read-only mode" do
    READ_ONLY_QUERIES.each do |code|
      it "allows #{code}" do
        result = validate(code)

        expect(result).to be_valid, "violations: #{result.violations.join("; ")}"
        expect(result).not_to be_writes
        expect(result).not_to be_destructive
      end
    end

    it "allows every column of every model to be read" do
      %w[id name country plan created_at updated_at].each do |column|
        expect(validate("Customer.first.#{column}")).to be_valid
      end
    end

    it "allows every association of every model to be walked" do
      %w[invoices support_tickets].each do |association|
        expect(validate("Customer.first.#{association}.count")).to be_valid
      end
      expect(validate("Invoice.first.customer.name")).to be_valid
    end

    it "allows boolean readers derived from columns" do
      expect(validate("Customer.first.plan?")).to be_valid
    end

    it "refuses a column that does not exist in the schema" do
      expect(validate("Customer.first.secret_token")).not_to be_valid
    end
  end

  describe "load" do
    [
      "Customer.all.load",
      "Customer.where(created_at: Date.new(2025)..).load",
      "Customer.joins(:invoices).distinct.load",
      "Customer.all.load.map(&:name)"
    ].each do |code|
      it "allows #{code}" do
        result = validate(code)

        expect(result).to be_valid, "violations: #{result.violations.join("; ")}"
        expect(result.writes).to be_empty
      end
    end

    [
      "load \"config/environment.rb\"",
      "load(\"/etc/passwd\")",
      "Kernel.load(\"config/boot.rb\")",
      "Marshal.load(Customer.first.to_json)",
      "YAML.load(File.read(\"config/database.yml\"))",
      "Object.load(\"x\")"
    ].each do |code|
      it "refuses #{code}" do
        expect(validate(code)).not_to be_valid
      end
    end

    it "still allows it in write mode without calling it a write" do
      result = validate("Customer.all.load", write_mode: true)

      expect(result).to be_valid
      expect(result.writes).to be_empty
    end
  end

  describe "constructors on value types" do
    VALUE_CONSTRUCTIONS = [
      "Customer.where(created_at: Date.new(2024)..Date.new(2025)).count",
      "Customer.where(created_at: Time.new(2024, 1, 1)..).count",
      "Invoice.where(due_date: Date.new(2024, 12, 31)).sum(:amount)",
      "Customer.where(created_at: DateTime.new(2024)..).count",
      "Customer.where(id: Range.new(1, 10)).count",
      "Customer.where(plan: Set.new(%w[pro free]).to_a).count",
      "Customer.where(country: Array.new(2) { |i| %w[HR DE][i] }).count",
      "Invoice.where(amount: BigDecimal.new(\"10.5\")..).count",
      "Customer.where(name: String.new(\"Acme\")).count"
    ].freeze

    VALUE_CONSTRUCTIONS.each do |code|
      it "allows #{code}" do
        result = validate(code)

        expect(result).to be_valid, "violations: #{result.violations.join("; ")}"
        expect(result.writes).to be_empty
      end
    end

    it "still treats a model constructor as a write" do
      %w[Customer.new Invoice.new].each do |code|
        result = validate(code)

        expect(result).not_to be_valid
        expect(result.writes).to include("new")
      end
    end

    it "still treats an association builder as a write" do
      result = validate("Customer.first.invoices.build(amount: 1)")

      expect(result).not_to be_valid
      expect(result.writes).to include("build")
    end

    it "keeps a model named like a value type on the write side" do
      allow(RailsAgentConsole::Schema).to receive(:model_names).and_return(%w[Date])

      result = validate("Date.new(2024)")

      expect(result).not_to be_valid
      expect(result.writes).to include("new")
    end

    it "does not let a constructor smuggle in a forbidden receiver" do
      expect(validate("File.new(\"/etc/passwd\")")).not_to be_valid
      expect(validate("Kernel.new")).not_to be_valid
    end
  end

  describe "write calls" do
    WRITE_CALLS.each do |method, code|
      context "with #{method}" do
        it "is refused in read-only mode and names the method" do
          result = validate(code)

          expect(result).not_to be_valid
          expect(result.violations.join(" ")).to include("`#{method}`").and include("read-only")
          expect(result.writes).to include(method)
        end

        it "is allowed in write mode" do
          expect(validate(code, write_mode: true)).to be_valid
        end

        it "reports nothing as merely unknown" do
          expect(validate(code).unknown).to be_empty
        end

        it "is classified as #{described_class::Rules::DESTRUCTIVE.include?(method) ? "destructive" : "harmless"}" do
          result = validate(code, write_mode: true)

          expect(result.destructive?).to eq(described_class::Rules::DESTRUCTIVE.include?(method))
        end
      end
    end
  end

  describe "calls that are never allowed" do
    ALWAYS_FORBIDDEN.each do |label, code|
      [false, true].each do |write_mode|
        it "refuses #{label} with write_mode=#{write_mode}" do
          expect(validate(code, write_mode: write_mode)).not_to be_valid
        end
      end
    end
  end

  describe "constants" do
    BLOCKED_CONSTANTS.each do |label, code|
      it "refuses #{label}" do
        result = validate(code, write_mode: true)

        expect(result).not_to be_valid
        expect(result.violations.join(" ")).to include(label)
      end
    end

    %w[Time Date DateTime Arel Customer Invoice SupportTicket].each do |constant|
      it "accepts #{constant}" do
        expect(validate("#{constant}.name").violations).to be_empty
      end
    end

    it "reports which models a query touches" do
      expect(validate("Customer.joins(:invoices).merge(Invoice.all).count").models)
        .to contain_exactly("Customer", "Invoice")
    end
  end

  describe "raw SQL" do
    [
      "Customer.where(\"1=1; DELETE FROM customers\")",
      "Customer.order(Arel.sql(\"name; DROP TABLE customers\"))",
      "Customer.select(Arel.sql(\"* FROM customers; UPDATE customers SET plan = 'free'\"))",
      "Invoice.where(\"amount > 0\").group(Arel.sql(\"status; TRUNCATE TABLE invoices\")).count",
      "Customer.find_by(\"name = 'x' -- \").tap { |c| c }"
    ].take(4).each do |code|
      it "refuses mutating SQL in #{code[0, 45]}..." do
        result = validate(code, write_mode: true)

        expect(result).not_to be_valid
        expect(result.violations.join(" ")).to include("raw SQL")
      end
    end

    [
      "Invoice.where(status: \"deleted\").count",
      "Customer.where(name: \"Update Ltd\").count",
      "Customer.where(\"name LIKE ?\", \"%insert%\").count",
      "Invoice.order(Arel.sql(\"amount DESC NULLS LAST\")).limit(5).pluck(:amount)"
    ].each do |code|
      it "allows harmless SQL and strings in #{code[0, 45]}..." do
        expect(validate(code)).to be_valid
      end
    end
  end

  describe "ruby constructs that have no place in a generated query" do
    {
      "a method definition" => "def boom; end",
      "a class definition" => "class Boom; end",
      "a module definition" => "module Boom; end",
      "a singleton class" => "class << Customer; end",
      "an instance variable" => "@customer.invoices",
      "a global variable" => "$stdout.puts(\"hi\")",
      "a class variable" => "@@cache",
      "an attribute assignment" => "Customer.first.name = \"x\"",
      "super" => "super"
    }.each do |label, code|
      it "refuses #{label}" do
        expect(validate(code, write_mode: true)).not_to be_valid
      end
    end

    {
      "Invoices" => "Invoice",
      "Tickets" => "SupportTicket",
      "Customr" => "Customer"
    }.each do |guess, model|
      it "suggests #{model} for the unknown constant #{guess}" do
        expect(validate("#{guess}.count").violations.first).to include("did you mean #{model}")
      end
    end

    it "refuses a column read off a Symbol, with the SQL way to write it" do
      violation = validate("Invoice.joins(:customer).where.not(status: :customer.country)").violations.first

      expect(violation).to include("`:customer.country` calls country on a Symbol", "customers.country")
    end

    it "still allows a symbol turned into a string" do
      expect(validate("Invoice.where(status: :paid.to_s).count")).to be_valid
    end

    [
      "AdminUser.first.password_digest",
      "User.pluck(:encrypted_password)",
      'User.where.not(reset_password_token: nil).pluck("api_token")',
      "User.select(:otp_secret)",
      "ApiKey.pluck(:api_key)"
    ].each do |code|
      it "blocks reading credentials: #{code}" do
        result = validate(code)

        expect(result).to be_blocked
        expect(result.violations.last).to include("holds a credential")
      end
    end

    it "allows asking whether a credential is set, which reveals nothing of it" do
      expect(validate("Customer.where.not(reset_password_token: nil).count").violations).to be_empty
    end

    it "still blocks a credential compared with a value" do
      expect(validate('Customer.where(reset_password_token: "abc").count')).to be_blocked
    end

    it "does not mistake a column like token_count for a credential" do
      expect(validate("Invoice.where(status: \"token_count\").count").violations).to be_empty
    end

    it "suggests nothing when nothing is close" do
      expect(validate("Warehouse.count").violations.first).to eq("constant `Warehouse` is not allowed")
    end

    it "refuses code that is not valid ruby" do
      expect(validate("Customer.where(").violations).to include(/not valid Ruby/)
    end

    it "says what the parser objected to" do
      violations = validate("Customer.where('status = 'cancelled'')").violations

      expect(violations.first).to match(/not valid Ruby: syntax error/)
    end

    it "refuses empty code" do
      expect(validate("   ").violations).to include("empty code")
    end

    it "refuses a column name used without a receiver" do
      result = validate("Customer.where('email LIKE ?', '%' || country || '.com')")

      expect(result).not_to be_valid
      expect(result.violations).to include("`country` is not on the read-only allowlist")
      expect(result).to be_repairable
    end

    it "still allows a column read on a receiver" do
      expect(validate("Customer.all.map { |one| one.country }")).to be_valid
    end

    it "does not mistake block parameters for method calls" do
      result = validate("Customer.all.group_by { |whatever| whatever.country }")

      expect(result).to be_valid
      expect(result.methods).not_to include("whatever")
    end

    it "does not mistake symbols for method calls" do
      result = validate("Customer.order(:destroy_all).limit(1)")

      expect(result.methods).not_to include("destroy_all")
    end

    it "allows local variables inside a block" do
      expect(validate("Customer.all.map { |c| total = c.invoices.sum(:amount); total }")).to be_valid
      expect(validate("Customer.all.map { |c| c.invoices.sum(:amount) }.sum")).to be_valid
    end
  end

  describe "configurable allowlists" do
    it "accepts extra methods once they are allowed" do
      expect(validate("Customer.all.to_csv")).not_to be_valid

      RailsAgentConsole.configuration.extra_allowed_methods = %w[to_csv]

      expect(validate("Customer.all.to_csv")).to be_valid
    end

    it "accepts extra constants once they are allowed" do
      expect(validate("MyReport.generate(Customer.all)")).not_to be_valid

      RailsAgentConsole.configuration.extra_allowed_constants = %w[MyReport]
      RailsAgentConsole.configuration.extra_allowed_methods = %w[generate]

      expect(validate("MyReport.generate(Customer.all)")).to be_valid
    end

    it "does not let an extra method unlock a write call" do
      RailsAgentConsole.configuration.extra_allowed_methods = %w[delete_all]

      expect(validate("Customer.delete_all")).not_to be_valid
    end
  end

  describe "#repairable?" do
    [
      "Customer.where.not(length(postal_code): 5)",
      "Customer.all.to_csv",
      "ApiKey.pluck(:label)",
      "SearchResult.select(Arel.sql(\"COUNT(*) AS total\")).map { |r| r.total }"
    ].each do |code|
      it "asks again about #{code}" do
        result = validate(code)

        expect(result).not_to be_valid
        expect(result).to be_repairable
        expect(result).not_to be_blocked
      end
    end

    [
      "Customer.delete_all",
      "Customer.first.update(country: \"HR\")",
      "Customer.connection.execute(\"SELECT 1\")",
      "File.read(\"/etc/passwd\")",
      "ENV[\"OPENAI_API_KEY\"]",
      "Customer.order(Arel.sql(\"name; DROP TABLE customers\"))",
      "`ls`",
      "@secret"
    ].each do |code|
      it "never asks again about #{code}" do
        result = validate(code)

        expect(result).not_to be_valid
        expect(result).not_to be_repairable
      end
    end

    it "is false for code that is already valid" do
      expect(validate("Customer.count")).not_to be_repairable
    end
  end

  describe "the result object" do
    it "names the calls that are only unfamiliar" do
      expect(validate("Customer.all.to_csv").unknown).to eq(%w[to_csv])
      expect(validate("Customer.all.to_csv.encrypt").unknown).to contain_exactly("to_csv", "encrypt")
    end

    it "keeps forbidden and write calls out of the unknown list" do
      expect(validate("Customer.delete_all").unknown).to be_empty
      expect(validate("Customer.all.send(:load)").unknown).to be_empty
    end

    it "describes itself" do
      expect(validate("Customer.count").to_s).to eq("valid")
      expect(validate("Customer.delete_all").to_s).to start_with("invalid:")
    end

    it "de-duplicates repeated violations" do
      result = validate("Customer.delete_all + Invoice.delete_all")

      expect(result.violations.count { |v| v.include?("delete_all") }).to eq(1)
    end
  end
end
