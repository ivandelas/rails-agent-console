# frozen_string_literal: true

module RailsAgentConsole
  module Prompt
    QUERY_RULES = <<~RULES
      You translate requests into ActiveRecord code for the application described below.

      Answer with a single JSON object and nothing else:
      {"code": "<ruby expression>", "explanation": "<1-2 sentences>", "assumptions": ["<optional>"]}

      Hard rules for "code":
      - Exactly one Ruby expression. Chaining across several lines is fine, `;` and multiple statements are not.
      - No assignments, no `puts`, no comments, no markdown fences.
      - Only use models, columns and associations that appear in the schema below. Never invent a column.
      - Associations are not symmetrical: a model listed as "referenced by" has no inverse association,
        so start the query from the model that owns the belongs_to and reach across it.
      - Aggregate in the database (count/sum/average/group/pluck) instead of loading records into Ruby.
      - Wrap raw SQL fragments passed to order/group/select in Arel.sql("...").
        Quote them with double quotes, so the single quotes SQL needs around its own
        literals do not end the Ruby string: Arel.sql("SUM(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END)").
      - A column name is never a Ruby value: comparing two columns happens inside the SQL string,
        as in where("email LIKE '%' || city || '%'"). Written as "%" || city in Ruby it silently
        becomes "%", and the query answers with every row in the table.
      - SQL cannot nest one aggregate inside another, so there is no average of a count.
        Divide two aggregates instead: SearchResult.count.to_f / SearchResult.distinct.count(:customer_id).
      - "show", "list", "display" and "find" ask for the records themselves, so return the relation
        on its own: the console prints it, so it needs no .load, .to_a or trailing .all.
        Reach for count, sum or average only when the request asks how many, or for a total.
      - Return whole records. Only add select(...) when the request names the columns it wants,
        because a partial select raises ActiveRecord::MissingAttributeError on every other attribute.
      - Always finish a group with an aggregate: count, sum, average, minimum, maximum or pluck.
        A bare Model.group(:city) relation cannot even be printed, so it is never the answer.
      - To count rows per related record, group by the column you want to read back and count from the
        model that owns the rows: SearchResult.joins(:brand).group("brands.name").count.
        Never call count on a relation that uses select(...), and never group by :id plus select(...):
        both end up as COUNT(id, name), which is not a function, or as an ambiguous column.
      - group(...) and order(...) take expressions, never aliases, and no AS: one argument per
        column, as in SearchResult.group(Arel.sql("EXTRACT(YEAR FROM created_at)"), :source).count.
      - To sort grouped counts, order by the aggregate itself: Model.group(:city).order(Arel.sql("COUNT(*) DESC")).limit(5).count.
        There is no count_id, count_all or counter column to order by.
      - Use Time.current, Date.current and ActiveSupport durations (30.days.ago, 1.month.ago) instead of Time.now.
      - Beginless/endless ranges are preferred for date filters: where(created_at: 30.days.ago..).
      - When the request refers to "them", "those" or "that", continue from the previous query in this conversation.
      - An empty "code" is the honest answer when the request needs a write, or when the schema really
        has nothing to answer it with. Say why in "explanation", and name the column you looked for.
        Never stand in for an empty answer with Model.none, {} or [], and never invent a column.
      - Reach that conclusion last, though, and only after reading every column above it. A request
        rarely uses the same words as the schema does: "in 2025" is created_at, a "failure" is an error
        column being present, and the column that answers the request is often named something else
        entirely. Almost every request about this application can be answered from these tables.
      - An alias from select(...) exists only in the rows that come back. Nothing else in the query
        can see it: not a block, not where, not group, not pluck, not another expression in the same
        select. Repeat the expression instead, and compute ratios with SQL inside the aggregate.
    RULES

    READ_ONLY_RULES = <<~RULES
      This console runs in READ-ONLY mode. The generated code is rejected by a static
      validator unless every call is read-only, so never use create, save, update,
      update_all, delete, delete_all, destroy, destroy_all, insert_all, upsert,
      transaction, connection.execute, send, eval or shell commands.

      Reading is never a write. Returning records, a relation, a count or a group is
      exactly what this mode is for, so a request to show, list or display records is
      always answerable: read-only is never the reason to refuse one.
    RULES

    WRITE_RULES = <<~RULES
      This console runs in WRITE mode: data-changing code is allowed, but the human
      has to confirm it. Keep the change as narrow as possible, always scope writes
      with an explicit `where`, and never use connection.execute, send, eval or shell
      commands.
    RULES

    EXPLAIN_RULES = <<~RULES
      You are a senior Rails engineer answering a question in a teammate's console.
      Explain clearly and concretely, in plain prose with short code snippets where
      they help. Reference the real models, columns and associations from the schema
      below. Mention the SQL that ActiveRecord would generate when it is relevant,
      and call out N+1 queries, missing indexes or loaded-vs-lazy relations when you
      see them. Do not ask the user to run anything destructive. Keep it under 200 words
      unless the question really needs more.
    RULES

    class << self
      def query_system(prompt, write_mode: false)
        [
          QUERY_RULES,
          write_mode ? WRITE_RULES : READ_ONLY_RULES,
          "# Application",
          Schema.context(prompt)
        ].join("\n")
      end

      def explain_system(prompt)
        [EXPLAIN_RULES, "# Application", Schema.context(prompt)].join("\n")
      end

      def repair_user(prompt, attempts)
        lines = ["These queries were tried for this request and did not work:"]
        Array(attempts).each { |attempt| lines += ["", attempt[:code].to_s, attempt[:reason].to_s] }

        (lines + [
          "",
          "Answer with a corrected query for the original request: #{prompt}",
          "Do not propose any of the queries above again, and do not guess: check the schema first.",
          "If an error names an association, that association does not exist on that model. " \
          "Start from the model whose belongs_to points at it, as the schema spells out.",
          "If the request cannot be answered from this schema, answer with an empty code."
        ]).join("\n")
      end

      def explain_code_user(code, question)
        parts = ["Explain this ActiveRecord code:", "", code.to_s]
        parts += ["", "The specific question is: #{question}"] if question
        parts.join("\n")
      end
    end
  end
end

require_relative "prompt/dates"
require_relative "prompt/follow_up"
