# frozen_string_literal: true

RSpec.describe RailsAgentConsole::Rewriter do
  def rewrite(code)
    described_class.apply(code)
  end

  describe "a join across a has_many that does not exist" do
    it "writes the join out in SQL" do
      result = rewrite("Customer.joins(:page_views).distinct.count")

      expect(result.code).to eq(
        'Customer.joins("INNER JOIN page_views ON page_views.customer_id = customers.id").distinct.count'
      )
      expect(result.notes.first).to include("Customer has no has_many for page_views")
    end

    it "runs, and counts what the association would have counted" do
      code = rewrite("Customer.joins(:page_views).distinct.count").code

      expect(RailsAgentConsole::Executor.run(code).value).to eq(PageView.distinct.count(:customer_id))
    end

    it "keeps a left join a left join" do
      expect(rewrite("Customer.left_joins(:page_views).where(page_views: { id: nil })").code)
        .to eq('Customer.joins("LEFT OUTER JOIN page_views ON page_views.customer_id = customers.id")' \
               ".where(page_views: { id: nil })")
    end

    it "leaves the real associations in the same call alone" do
      expect(rewrite("Customer.joins(:invoices, :page_views).count").code)
        .to eq("Customer.joins(:invoices)" \
               '.joins("INNER JOIN page_views ON page_views.customer_id = customers.id").count')
    end

    {
      "an association that exists" => "Customer.joins(:invoices).count",
      "a name nothing points back with" => "Customer.joins(:orders).count",
      "a join inside a subquery" => "Customer.where(id: Invoice.joins(:customer).select(:customer_id))",
      "a join after the chain has left the model" => "Customer.first.invoices.joins(:page_views)",
      "a model that is not in the schema" => "Order.joins(:page_views)",
      "a nested join" => "Customer.joins(page_views: :customer)"
    }.each do |label, code|
      it "leaves #{label} alone" do
        expect(rewrite(code)).to have_attributes(code: code, notes: [])
      end
    end
  end

  describe "a relation method after an aggregate" do
    it "moves order and limit in front of it" do
      result = rewrite('Customer.group(:country).count.order(Arel.sql("COUNT(*) DESC")).limit(1)')

      expect(result.code).to eq('Customer.group(:country).order(Arel.sql("COUNT(*) DESC")).limit(1).count')
      expect(result.notes.first).to include("`order` and `limit` came after `count`")
    end

    it "gives the answer the original was reaching for" do
      code = rewrite('Customer.group(:country).count.order(Arel.sql("COUNT(*) DESC")).limit(1)').code

      expect(RailsAgentConsole::Executor.run(code).value.size).to eq(1)
    end

    {
      "Ruby that works on the result" => "Customer.group(:country).count.sort_by { |_, total| -total }.first(1)",
      "an aggregate at the end already" => "Customer.group(:country).order(:country).count",
      "an aggregate that is not on a relation" => "Customer.all.map(&:id).sum.limit(1)"
    }.each do |label, code|
      it "leaves #{label} alone" do
        expect(rewrite(code).code).to eq(code)
      end
    end
  end

  describe "a column that more than one joined table has" do
    it "reads it from the table the query starts from" do
      result = rewrite('Customer.joins(:invoices).where("created_at > ?", 1.year.ago).distinct.count')

      expect(result.code)
        .to eq('Customer.joins(:invoices).where("customers.created_at > ?", 1.year.ago).distinct.count')
      expect(result.notes.first).to include("`created_at` is in more than one of the joined tables")
    end

    it "runs where the original was ambiguous" do
      code = rewrite('Customer.joins(:invoices).where("created_at > ?", 1.year.ago).distinct.count').code

      expect(RailsAgentConsole::Executor.run(code)).to be_ok
    end

    it "leaves a subquery alone, since it reads its own table" do
      code = 'Customer.joins(:invoices).group("customers.id")' \
             '.having("COUNT(*) > (SELECT COUNT(*) FROM invoices WHERE created_at > \'2025-01-01\') / 10")' \
             '.where("created_at > ?", 1.year.ago)'
      result = rewrite(code)

      expect(result.code).to include("(SELECT COUNT(*) FROM invoices WHERE created_at > '2025-01-01')")
      expect(result.code).to include('where("customers.created_at > ?"')
      expect(RailsAgentConsole::Executor.run(result.code)).to be_ok
    end

    it "reaches into aggregates and functions" do
      expect(rewrite("Invoice.joins(:customer).group(Arel.sql(\"strftime('%m', created_at)\")).count").code)
        .to eq("Invoice.joins(:customer).group(Arel.sql(\"strftime('%m', invoices.created_at)\")).count")
    end

    it "qualifies the tables joined by spelling out a missing has_many too" do
      expect(rewrite("Customer.joins(:page_views).where(\"created_at > '2020-01-01'\").count").code)
        .to include("where(\"customers.created_at > '2020-01-01'\")")
    end

    {
      "a query with no join" => 'Customer.where("created_at > ?", 1.year.ago).count',
      "a column that is already qualified" => 'Customer.joins(:invoices).where("invoices.created_at > ?", 1.day.ago)',
      "a column only one table has" => "Customer.joins(:invoices).where(\"status = 'paid'\").count",
      "a hash condition" => "Customer.joins(:invoices).where(created_at: 1.year.ago..).count",
      "an alias" => 'Customer.joins(:invoices).select("MAX(invoices.id) AS id")'
    }.each do |label, code|
      it "leaves #{label} alone" do
        expect(rewrite(code).code).to eq(code)
      end
    end
  end

  describe "an association name used as a table" do
    it "renames it to the table" do
      result = rewrite("Invoice.joins(:customer).where(\"customer.country = 'HR'\").count")

      expect(result.code).to eq("Invoice.joins(:customer).where(\"customers.country = 'HR'\").count")
      expect(result.notes.first).to include("`customer.` is the association; SQL needs the table, customers")
    end

    it "runs, where the original named a table that is not in the query" do
      code = rewrite("Invoice.joins(:customer).where(\"customer.country = 'HR'\").count").code
      expected = Invoice.joins(:customer).where(customers: { country: "HR" }).count

      expect(RailsAgentConsole::Executor.run(code).value).to eq(expected)
    end

    it "leaves an association that is not joined alone" do
      code = "Invoice.where(\"customer.country = 'HR'\").count"

      expect(rewrite(code).code).to eq(code)
    end
  end

  describe "arguments" do
    {
      "Invoice.where(due_date: paid_at).count" => 'Invoice.where("invoices.due_date = invoices.paid_at").count',
      "Invoice.where.not(due_date: paid_at).count" =>
        'Invoice.where.not("invoices.due_date = invoices.paid_at").count',
      "Invoice.joins(:customer).order(customer: :name).limit(3)" =>
        'Invoice.joins(:customer).order("customers.name").limit(3)',
      'Customer.pluck("UPPER(name)")' => 'Customer.pluck(Arel.sql("UPPER(name)"))',
      "Customer.order('LENGTH(name) DESC').first" => "Customer.order(Arel.sql('LENGTH(name) DESC')).first",
      "Customer.joins(:invoices).group(:name).count(:invoices_id)" =>
        'Customer.joins(:invoices).group(:name).count("invoices.id")',
      "Invoice.joins(:customer).joins(:support_tickets).count" =>
        "Invoice.joins(:customer).joins(customer: :support_tickets).count",
      'Customer.joins(:invoices).where(status: "paid").distinct.count' =>
        'Customer.joins(:invoices).where(invoices: { status: "paid" }).distinct.count',
      "Invoice.group(:status).order(:due_date).count" =>
        'Invoice.group(:status).order(Arel.sql("MIN(invoices.due_date)")).count',
      "Invoice.group(:status).order(due_date: :desc).count" =>
        'Invoice.group(:status).order(Arel.sql("MIN(invoices.due_date) DESC")).count',
      "Customer.group(Arel.sql('strftime('%Y', created_at)')).count" =>
        "Customer.group(Arel.sql(\"strftime('%Y', created_at)\")).count",
      "Customer.group(Arel.sql('plan || '-' || country')).count" =>
        "Customer.group(Arel.sql(\"plan || '-' || country\")).count",
      "Customer.where('plan IN ('a', 'b')').count" => "Customer.where(\"plan IN ('a', 'b')\").count",
      'Invoice.joins(:customer).where(customer: { country: "HR" }).where(customers: { plan: "pro" }).count' =>
        'Invoice.joins(:customer).where(customers: { country: "HR" }).where(customers: { plan: "pro" }).count',
      'Invoice.joins(:customer).distinct.order("customers.name").limit(3)' =>
        'Invoice.joins(:customer).order("customers.name").limit(3)',
      "Invoice.joins(:customer).order(customers: :name).limit(3)" =>
        'Invoice.joins(:customer).order("customers.name").limit(3)'
    }.each do |code, corrected|
      it "corrects #{code}" do
        expect(rewrite(code).code).to eq(corrected)
        expect(RailsAgentConsole::Executor.run(corrected)).to be_ok
      end
    end

    it "turns today's weekday into each row's weekday" do
      expect(rewrite("Customer.where(created_at: (Time.current.wday == 0 || Time.current.wday == 6)).count").code)
        .to eq('Customer.where("EXTRACT(DOW FROM customers.created_at) IN (0, 6)").count')
    end

    {
      "a weekday mixed with other Ruby" => "Customer.where(created_at: (Time.current.wday == 0 && 1.day.ago)).count",
      "a hash value that is not a column" => "Invoice.where(status: paid).count",
      "nil" => "Invoice.where(paid_at: nil).count",
      "a plain column in pluck" => 'Customer.pluck("name")',
      "an ordering direction" => "Customer.order(name: :desc)",
      "count of a real column" => "Customer.joins(:invoices).count(:name)",
      "a key on the model itself" => 'Customer.joins(:invoices).where(name: "Ivan").count',
      "an order by the grouped column" => "Invoice.group(:status).order(:status).count",
      "quotes that already parse" => "Customer.where(\"name = 'x'\").count",
      "separate string arguments" => "Customer.where('name = ? OR plan = ?', 'a', 'b').count",
      "distinct over a has_many join" => 'Customer.joins(:invoices).distinct.order("invoices.amount").limit(3)',
      "distinct ordered by its own columns" => "Invoice.joins(:customer).distinct.order(:amount)",
      "a hash keyed by the table already" => 'Invoice.joins(:customer).where(customers: { country: "HR" }).count'
    }.each do |label, code|
      it "leaves #{label} alone" do
        expect(rewrite(code).code).to eq(code)
      end
    end
  end

  describe "first on a grouped relation" do
    it "plucks the grouped column of the top group" do
      code = 'Invoice.group(:status).order(Arel.sql("SUM(amount) DESC")).first.status'
      corrected = 'Invoice.group(:status).order(Arel.sql("SUM(amount) DESC")).limit(1).pluck(:status).first'

      expect(rewrite(code).code).to eq(corrected)
      expect(RailsAgentConsole::Executor.run(corrected)).to be_ok
    end

    it "leaves first alone without a group" do
      expect(rewrite("Invoice.order(:amount).first").code).to eq("Invoice.order(:amount).first")
    end
  end

  describe "a count divided by a count" do
    it "divides as decimals, since whole-number division rounds a rate down to 0" do
      code = "Invoice.group(:status).pluck(:status, " \
             'Arel.sql("SUM(CASE WHEN paid_at IS NULL THEN 1 ELSE 0 END) / COUNT(*)"))'
      result = rewrite(code)

      expect(result.code).to include("SUM(CASE WHEN paid_at IS NULL THEN 1 ELSE 0 END) * 1.0 / COUNT(*)")
      expect(result.notes.join).to include("whole-number division")
      expect(RailsAgentConsole::Executor.run(result.code).value.to_h["unpaid"]).to eq(1.0)
    end

    it "leaves a division that is already decimal alone" do
      code = 'Invoice.pluck(Arel.sql("1.0 * COUNT(paid_at) / COUNT(*)"))'

      expect(rewrite(code).code).to eq(code)
    end
  end

  describe "an association named with a bare word" do
    it "turns it into a symbol" do
      result = rewrite("Customer.joins(invoices).group(:country).count")

      expect(result.code).to eq("Customer.joins(:invoices).group(:country).count")
      expect(RailsAgentConsole::Executor.run(result.code)).to be_ok
    end

    it "leaves a word that is not an association alone" do
      expect(rewrite("Customer.joins(tables).count").code).to eq("Customer.joins(tables).count")
    end
  end

  describe "a range that ends on a date" do
    it "runs to the end of that day" do
      code = 'Invoice.where(created_at: Time.zone.parse("2025-01-01")..Time.zone.parse("2025-12-31"))'
      result = rewrite(code)

      expect(result.code).to eq(
        'Invoice.where(created_at: Time.zone.parse("2025-01-01")..Time.zone.parse("2025-12-31").end_of_day)'
      )
      expect(result.notes.join).to match(/end_of_day/)
    end

    it "leaves exclusive ranges, times and end_of_day alone" do
      [
        'Invoice.where(created_at: Time.zone.parse("2025-01-01")...Time.zone.parse("2026-01-01"))',
        'Invoice.where(created_at: Time.zone.parse("2025-01-01")..Time.zone.parse("2025-12-31 23:59"))',
        'Invoice.where(created_at: Time.zone.parse("2025-01-01")..Time.zone.parse("2025-12-31").end_of_day)'
      ].each { |code| expect(rewrite(code).code).to eq(code) }
    end
  end

  describe "SQL inside strings" do
    {
      'Customer.group(:country).order(Arel.sql("AVG LENGTH(name) DESC")).count' =>
        'Customer.group(:country).order(Arel.sql("AVG(LENGTH(name)) DESC")).count',
      'Customer.where("name length > 3").count' => 'Customer.where("LENGTH(name) > 3").count',
      "Customer.group(Arel.sql(\"strftime('%Y', created_at) AS year\")).count" =>
        "Customer.group(Arel.sql(\"strftime('%Y', created_at)\")).count"
    }.each do |code, corrected|
      it "corrects #{code}" do
        expect(rewrite(code).code).to eq(corrected)
        expect(RailsAgentConsole::Executor.run(corrected)).to be_ok
      end
    end

    it "casts an extracted number to text before padding it" do
      expect(rewrite("Customer.group(Arel.sql(\"LPAD(EXTRACT(MONTH FROM created_at), 2, '0')\")).count").code)
        .to eq("Customer.group(Arel.sql(\"LPAD(EXTRACT(MONTH FROM created_at)::text, 2, '0')\")).count")
    end

    it "averages a timestamp as seconds" do
      expect(rewrite('Invoice.group(:status).order(Arel.sql("AVG(paid_at)")).count').code)
        .to eq('Invoice.group(:status).order(Arel.sql("AVG(EXTRACT(EPOCH FROM paid_at))")).count')
    end

    {
      "a cast" => 'Customer.group(Arel.sql("CAST(plan AS text)")).count',
      "an alias in select" => 'Customer.select("COUNT(*) AS total")',
      "the average of a number" => 'Invoice.order(Arel.sql("AVG(amount)"))',
      "a length function" => 'Customer.where("LENGTH(name) > 3")'
    }.each do |label, code|
      it "leaves #{label} alone" do
        expect(rewrite(code).code).to eq(code)
      end
    end
  end

  it "applies both corrections to one query" do
    result = rewrite('Customer.joins(:page_views).group(:country).count.order(Arel.sql("COUNT(*) DESC"))')

    expect(result.code).to eq(
      'Customer.joins("INNER JOIN page_views ON page_views.customer_id = customers.id")' \
      '.group(:country).order(Arel.sql("COUNT(*) DESC")).count'
    )
    expect(result.notes.size).to eq(2)
  end

  {
    "arithmetic between two queries" => "Customer.count.to_f / Invoice.count",
    "a do/end block" => "Customer.all.each do |customer| customer end",
    "an argument without parentheses" => "Customer.where 'id > 1'",
    "a multi-line chain it does not need to touch" => "Customer.joins(:invoices)\n  .group(:name)\n  .count",
    "code that does not parse" => "Customer.where(",
    "a range" => "Customer.where(created_at: 30.days.ago..).count"
  }.each do |label, code|
    it "leaves #{label} alone" do
      expect(rewrite(code).code).to eq(code)
    end
  end

  describe "the proposal" do
    it "carries the correction, and the agent shows it" do
      run_agent("customers with page views", code: "Customer.joins(:page_views).distinct.count")

      expect(printed).to include("Corrected: Customer has no has_many for page_views", "✓ 2")
    end
  end
end
