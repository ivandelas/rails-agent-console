# frozen_string_literal: true

RSpec.describe RailsAgentConsole::Agent do
  subject(:agent) { RailsAgentConsole.agent }

  describe "#run" do
    context "with a safe query" do
      it "proposes, asks and executes" do
        result = run_agent("how many customers?", code: "Customer.count")

        expect(result).to eq(2)
        expect(printed).to include("Proposed query:", "Customer.count", "Execute?")
      end

      it "returns the relation and reports the row count up front" do
        result = run_agent("show me the customers", code: "Customer.all")

        expect(result.size).to eq(2)
        expect(printed).to include("Found 2 records.")
      end

      it "narrates the models it touches" do
        run_agent("customers with invoices", code: "Customer.joins(:invoices).distinct.count")

        expect(printed).to include("Inspecting application...", "has_many :invoices")
      end

      it "reports how long the query took" do
        run_agent("how many customers?", code: "Customer.count")

        expect(printed).to match(/✓ 2 in \d+ms/)
      end

      it "counts the groups and says so when the query forgot its aggregate" do
        result = run_agent("group customers by city", code: "Customer.group(:country)")

        expect(result).to eq({ "HR" => 1, "DE" => 1 })
        expect(printed).to include("✓ 2 groups", "no aggregate after `group`")
      end
    end

    context "when the query fails in the database" do
      let(:broken) { "PageView.joins(:customers).count" }

      it "sends the error back to the model and runs the corrected query" do
        result = run_agent("how many page views?", code: [broken, "PageView.count"], answers: %w[y y])

        expect(result).to eq(2)
        expect(printed).to include("ActiveRecord::ConfigurationError", "Fixing the query...", "PageView.count")
      end

      it "catches a relation that only fails once it is loaded" do
        result = run_agent("page views", code: ["PageView.joins(:customers)", "PageView.count"], answers: %w[y y])

        expect(result).to eq(2)
        expect(printed).to include("ActiveRecord::ConfigurationError", "Fixing the query...")
      end

      it "quotes the failed code and the error to the model" do
        run_agent("how many page views?", code: [broken, "PageView.count"], answers: %w[y y])

        expect(last_request[:messages].last[:content]).to include(broken, "ActiveRecord::ConfigurationError")
      end

      it "adds the diagnosis to the error it sends back" do
        run_agent("how many page views?", code: [broken, "PageView.count"], answers: %w[y y])

        expect(last_request[:messages].last[:content]).to include("no `customers` association on PageView")
      end

      it "still validates and confirms the correction" do
        result = run_agent("how many page views?", code: [broken, "Customer.delete_all"], answers: %w[y y])

        expect(result).to be_nil
        expect(printed).to include("Refusing to run this code.")
        expect(Customer.count).to eq(2)
      end

      it "stops when the model comes back with a query it already tried" do
        expect(run_agent("how many page views?", code: broken, answers: %w[y y])).to be_nil

        expect(printed).to include("The model came back with a query it had already tried.")
      end

      it "does not run an earlier attempt a second time" do
        run_agent("how many page views?", code: [broken, "Customer.joins(:nope).count", broken],
                                          answers: %w[y y y])

        expect(printed.scan("Can't join 'PageView' to association named 'customers'").size).to eq(1)
        expect(printed).to include("The model came back with a query it had already tried.")
      end

      it "retries only as often as configured" do
        RailsAgentConsole.configuration.max_repair_attempts = 1

        run_agent("how many page views?", code: [broken, "Customer.joins(:nope).count"], answers: %w[y y y])

        expect(printed.scan("Fixing the query...").size).to eq(1)
      end

      it "does not retry when repairs are switched off" do
        RailsAgentConsole.configuration.max_repair_attempts = 0

        expect(run_agent("how many page views?", code: [broken, "PageView.count"])).to be_nil
        expect(printed).not_to include("Fixing the query...")
      end
    end

    context "when the code is refused" do
      it "retries invalid Ruby" do
        result = run_agent("odd postal codes", code: ["Customer.where.not(length(x): 5)", "Customer.count"],
                                               answers: %w[y y])

        expect(result).to eq(2)
        expect(printed).to include("the code is not valid Ruby", "Fixing the query...")
      end

      it "retries an unfamiliar call" do
        result = run_agent("export them", code: ["Customer.all.to_csv", "Customer.count"], answers: %w[y y])

        expect(result).to eq(2)
        expect(printed).to include("Fixing the query...")
      end

      it "retries a constant the schema does not have" do
        run_agent("api keys", code: ["ApiKey.pluck(:label)", "Customer.count"], answers: %w[y y])

        expect(printed).to include("constant `ApiKey` is not allowed", "Fixing the query...")
      end

      it "retries a correction that is refused in turn" do
        result = run_agent("api keys", code: ["ApiKey.pluck(:label)", "Vault.pluck(:label)", "Customer.count"],
                                       answers: %w[y y y])

        expect(result).to eq(2)
        expect(printed.scan("Fixing the query...").size).to eq(2)
      end

      { "a write" => "Customer.delete_all",
        "a forbidden call" => "Customer.connection.execute(\"SELECT 1\")",
        "a constant that leaves the database" => "File.read(\"/etc/passwd\")",
        "raw SQL that mutates" => "Customer.order(Arel.sql(\"name; DROP TABLE customers\"))" }.each do |what, code|
        it "does not retry #{what}" do
          expect(run_agent("do it", code: code)).to be_nil

          expect(printed).to include("Refusing to run this code.")
          expect(printed).not_to include("Fixing the query...")
        end
      end
    end

    context "when the model stands in for a decline" do
      ["Customer.none", "{}", "[]", "nil"].each do |code|
        it "treats #{code} as no query at all" do
          expect(run_agent("drop the customers table", code: code)).to be_nil

          expect(printed).to include("No query to run.")
          expect(printed).not_to include("Execute?")
        end
      end

      it "keeps a real query that merely uses none" do
        run_agent("nothing for free customers", code: "Customer.where(plan: \"free\").none.count")

        expect(printed).to include("Execute?")
      end
    end

    context "when the developer declines" do
      it "does not execute and returns nil" do
        expect(run_agent("show me the customers", code: "Customer.all", answers: ["n"])).to be_nil
      end

      %w[n no N NO].each do |answer|
        it "treats #{answer.inspect} as a refusal" do
          expect(run_agent("delete nothing", code: "Customer.all", answers: [answer])).to be_nil
        end
      end

      %w[y yes Y YES].each do |answer|
        it "treats #{answer.inspect} as consent" do
          expect(run_agent("count", code: "Customer.count", answers: [answer])).to eq(2)
        end
      end

      it "defaults to refusing when the answer is empty" do
        expect(run_agent("count", code: "Customer.count", answers: [""])).to be_nil
      end
    end

    context "with unsafe code" do
      it "refuses before asking anything" do
        expect(run_agent("remove every customer", code: "Customer.delete_all")).to be_nil

        expect(printed).to include("Refusing to run this code.", "read-only mode")
        expect(printed).not_to include("Execute?")
        expect(Customer.count).to eq(2)
      end

      it "suggests write mode when the problem is a write" do
        run_agent("remove every customer", code: "Customer.delete_all")

        expect(printed).to include("Use `ai!` for a single write")
      end

      it "suggests the allowlist when the problem is an unknown call" do
        run_agent("export them", code: "Customer.all.to_csv")

        expect(printed).to include("extra_allowed_methods << \"to_csv\"")
      end

      it "does not blame read-only mode in write mode" do
        run_agent("add a customer", code: "Customer.create(name: \"Acme\", plan: rand_plan)", write: true)

        expect(printed).to include("extra_allowed_methods << \"rand_plan\"")
        expect(printed).not_to include("Read-only mode is on")
      end

      it "still blames read-only mode for a write outside write mode" do
        run_agent("add a customer", code: "Customer.create(name: \"Acme\")")

        expect(printed).to include("Read-only mode is on")
      end

      it "never runs shell commands" do
        expect(run_agent("clean up", code: "system(\"touch /tmp/rails_agent_console_should_not_exist\")")).to be_nil
        expect(File.exist?("/tmp/rails_agent_console_should_not_exist")).to be(false)
      end
    end

    context "with a destructive statement in write mode" do
      let(:code) { "Customer.where(plan: \"free\").delete_all" }

      it "requires the confirmation word and reports the impact" do
        expect(run_agent("delete free customers", code: code, answers: ["y"], write: true)).to be_nil

        expect(printed).to include("DESTRUCTIVE OPERATION", "approximately 1 records", "Affected calls: delete_all")
        expect(Customer.count).to eq(2)
      end

      it "executes once the word is typed" do
        run_agent("delete free customers", code: code, answers: ["execute"], write: true)

        expect(Customer.count).to eq(1)
      end

      it "honours a custom confirmation word" do
        RailsAgentConsole.configuration.destructive_confirmation_word = "obriši"

        run_agent("delete free customers", code: code, answers: ["obriši"], write: true)

        expect(Customer.count).to eq(1)
      end
    end

    context "with a non-destructive write in write mode" do
      it "asks the normal question" do
        run_agent("touch the first customer", code: "Customer.first.touch", answers: ["y"], write: true)

        expect(printed).to include("Proposed command:", "Execute?")
        expect(printed).not_to include("DESTRUCTIVE")
      end
    end

    context "with auto_confirm" do
      it "skips the prompt entirely" do
        RailsAgentConsole.configuration.auto_confirm = true
        stub_client json_reply("Customer.count")

        expect(agent.run("count")).to eq(2)
        expect(printed).not_to include("Execute?")
      end

      it "still refuses unsafe code" do
        RailsAgentConsole.configuration.auto_confirm = true
        stub_client json_reply("Customer.delete_all")

        expect(agent.run("delete them")).to be_nil
        expect(Customer.count).to eq(2)
      end
    end

    context "when the query raises" do
      it "reports the error and keeps the console alive" do
        expect(run_agent("broken", code: "Customer.where(nope: 1).count")).to be_nil

        expect(printed).to match(/✗ ActiveRecord::StatementInvalid|✗ ActiveRecord::UnknownAttributeReference/)
      end

      it "remembers the failure in the conversation" do
        run_agent("broken", code: "Customer.where(nope: 1).count")

        expect(agent.history.last.outcome).to start_with("failed:")
      end
    end

    context "when the model misbehaves" do
      it "reports an answer that contains no code" do
        stub_client JSON.generate("code" => "", "explanation" => "I cannot help with that")
        answer_with "y"

        expect(agent.run("anything")).to be_nil
        expect(printed).to include("No query to run.").and include("I cannot help with that")
      end

      ["nil", "null", "None", "# I will not do that\n", "  "].each do |placeholder|
        it "does not offer to execute #{placeholder.strip.inspect}" do
          stub_client JSON.generate("code" => placeholder, "explanation" => "READ-ONLY mode")
          answer_with "y"

          expect(agent.run("delete all customers")).to be_nil
          expect(printed).to include("No query to run.").and include("READ-ONLY mode")
          expect(printed).not_to include("Execute?")
        end
      end

      it "falls back to a hint when the model explains nothing" do
        stub_client JSON.generate("code" => "nil")

        expect(agent.run("delete all customers")).to be_nil
        expect(printed).to include("No query to run.").and include("Rephrase the request")
      end

      it "refuses prose that is not ruby" do
        stub_client "I am afraid I cannot do that, Dave."
        answer_with "y"

        expect(agent.run("anything")).to be_nil
        expect(printed).to include("not valid Ruby")
      end

      it "still accepts a fenced code block" do
        stub_client "```ruby\nCustomer.count\n```"
        answer_with "y"

        expect(agent.run("count")).to eq(2)
      end
    end

    it "prints usage for an empty prompt" do
      expect(agent.run("")).to be_nil
      expect(printed).to include("Usage: ai")
    end
  end

  describe "conversation context" do
    it "feeds earlier turns back to the model" do
      stub_client json_reply("Customer.where(created_at: 30.days.ago..).count"),
                  json_reply("Customer.where(created_at: 30.days.ago..).group(:country).count")
      answer_with "y", "y"

      agent.run("customers created in the last 30 days")
      result = agent.run("group them by country")

      expect(result).to eq({ "HR" => 1 })
      messages = last_request[:messages]
      expect(messages.size).to eq(3)
      expect(messages[0][:content]).to eq("customers created in the last 30 days")
      expect(messages[1][:content]).to include("30.days.ago")
      expect(messages[2][:content]).to start_with("group them by country\n\nThis continues the previous query.")
    end

    it "keeps at most max_history turns" do
      RailsAgentConsole.configuration.max_history = 1
      stub_client json_reply("Customer.count")
      answer_with "y", "y", "y"

      3.times { |i| agent.run("question #{i}") }

      expect(agent.history.turns.size).to eq(1)
      expect(last_request[:messages].size).to eq(3)
    end

    it "forgets the conversation on reset" do
      run_agent("count", code: "Customer.count")

      agent.reset!

      expect(agent.history).to be_empty
    end
  end

  describe "the prompt sent to the model" do
    before do
      stub_client json_reply("Customer.count")
      answer_with "y"
    end

    it "includes the schema of the application" do
      agent.run("how many customers?")

      expect(last_request[:system]).to include("Customer (customers)", "has_many :invoices", "columns: id:integer")
    end

    {
      "partial selects" => "Only add select(...) when the request names the columns",
      "counting instead of listing" => "ask for the records themselves",
      "a group with no aggregate" => "Always finish a group with an aggregate",
      "ordering by count_id" => "order(Arel.sql(\"COUNT(*) DESC\"))",
      "single-quoted SQL fragments" => "Quote them with double quotes",
      "averaging a count" => "SQL cannot nest one aggregate inside another",
      "reusing a select alias" => "exists only in the rows that come back"
    }.each do |habit, rule|
      it "tells the model to avoid #{habit}" do
        agent.run("how many customers?")

        expect(last_request[:system]).to include(rule)
      end
    end

    it "states the read-only contract by default" do
      agent.run("how many customers?")

      expect(last_request[:system]).to include("READ-ONLY mode")
    end

    it "states the write contract in write mode" do
      agent.run("how many customers?", write: true)

      expect(last_request[:system]).to include("WRITE mode")
    end

    it "carries extra context from the configuration" do
      RailsAgentConsole.configuration.extra_context = "Revenue lives on Invoice#amount."

      agent.run("how much revenue?")

      expect(last_request[:system]).to include("Revenue lives on Invoice#amount.")
    end
  end

  describe "#ask" do
    it "explains without executing anything" do
      stub_client "Because `includes` turns N+1 queries into two."

      expect(agent.ask("why is includes faster?")).to be_nil
      expect(printed).to include("Because `includes` turns N+1")
      expect(last_request[:system]).to include("senior Rails engineer")
    end

    it "prints usage for an empty question" do
      expect(agent.ask(nil)).to be_nil
      expect(printed).to include("Usage: ai")
    end
  end

  describe "#explain" do
    it "passes the SQL of a relation" do
      stub_client "That query filters unpaid invoices."

      agent.explain(Invoice.where(status: "unpaid"))

      expect(last_request[:messages].last[:content])
        .to include("ActiveRecord::Relation on Invoice").and match(/SELECT .* FROM .invoices./)
    end

    it "passes a string through untouched" do
      stub_client "Explanation."

      agent.explain("Customer.includes(:invoices)")

      expect(last_request[:messages].last[:content]).to include("Customer.includes(:invoices)")
    end

    it "adds the question when one is given" do
      stub_client "Explanation."

      agent.explain("Customer.all", question: "is this slow?")

      expect(last_request[:messages].last[:content]).to include("is this slow?")
    end
  end

  describe "#propose" do
    it "returns a proposal without touching the database" do
      stub_client json_reply("Customer.delete_all")

      proposal = agent.propose("delete them")

      expect(proposal.code).to eq("Customer.delete_all")
      expect(proposal).not_to be_safe
      expect(Customer.count).to eq(2)
      expect(printed).to be_empty
    end
  end

  describe "failure handling" do
    it "reports a missing API key instead of calling out" do
      RailsAgentConsole.configure do |config|
        config.client = nil
        config.provider = :openai
        config.api_key = nil
      end
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("OPENAI_API_KEY", nil).and_return(nil)

      expect(described_class.new.run("anything")).to be_nil
      expect(printed).to include("No API key for openai")
    end

    it "reports provider failures" do
      RailsAgentConsole.configuration.client = ->(**_call) { raise RailsAgentConsole::ProviderError, "OpenAI 401" }

      expect(agent.run("anything")).to be_nil
      expect(printed).to include("OpenAI 401")
    end

    it "reports an invalid response" do
      RailsAgentConsole.configuration.client = ->(**_call) { "" }

      expect(agent.run("anything")).to be_nil
      expect(printed).to include("config.client returned nothing")
    end
  end
end
