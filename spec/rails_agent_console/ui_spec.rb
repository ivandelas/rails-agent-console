# frozen_string_literal: true

RSpec.describe RailsAgentConsole::UI do
  subject(:ui) { described_class.new(RailsAgentConsole.configuration) }

  class FakeTerminal
    attr_reader :echo_disabled

    def initialize(value)
      @value = value
      @echo_disabled = false
    end

    def tty?
      true
    end

    def gets
      @value
    end

    def noecho
      @echo_disabled = true
      yield self
    end
  end

  describe "#secret" do
    it "turns echo off on a terminal and never prints the value" do
      terminal = FakeTerminal.new("sk-secret\n")
      RailsAgentConsole.configuration.input = terminal

      expect(ui.secret("API key:")).to eq("sk-secret")
      expect(terminal.echo_disabled).to be(true)
      expect(printed).not_to include("sk-secret")
    end

    it "still works when the input is piped" do
      answer_with "sk-piped"

      expect(ui.secret("API key:")).to eq("sk-piped")
    end
  end

  describe "#yes?" do
    {
      "y" => true, "Y" => true, "yes" => true, "YES" => true,
      "n" => false, "N" => false, "no" => false, "NO" => false
    }.each do |answer, expected|
      it "reads #{answer.inspect} as #{expected}" do
        answer_with answer

        expect(ui.yes?("Execute?")).to be(expected)
      end
    end

    it "uses the default for an empty answer" do
      answer_with ""
      expect(ui.yes?("Store it?", default: true)).to be(true)

      answer_with ""
      expect(ui.yes?("Execute?", default: false)).to be(false)
    end

    it "uses the default for nonsense" do
      answer_with "maybe"

      expect(ui.yes?("Execute?", default: false)).to be(false)
    end

    it "shows which answer is the default" do
      answer_with ""
      ui.yes?("Store it?", default: true)

      expect(printed).to include("[Y/n]")
    end
  end

  describe "#ask" do
    it "returns the trimmed answer" do
      answer_with "  gpt-4o  "

      expect(ui.ask("Model:")).to eq("gpt-4o")
    end

    it "returns the default for an empty answer" do
      answer_with ""

      expect(ui.ask("Model:", default: "gpt-4o-mini")).to eq("gpt-4o-mini")
    end

    it "returns the default at end of input" do
      RailsAgentConsole.configuration.input = StringIO.new("")

      expect(ui.ask("Model:", default: "fallback")).to eq("fallback")
    end
  end

  describe "formatting" do
    it "drops colour when the output is not a terminal" do
      expect(ui.colorize("plain", :red)).to eq("plain")
      expect(ui.bold("plain")).to eq("plain")
      expect(ui.dim("plain")).to eq("plain")
    end

    it "emits ANSI codes when colour is on" do
      RailsAgentConsole.configuration.color = true

      expect(ui.colorize("red", :red)).to eq("\e[31mred\e[0m")
      expect(ui.bold("b")).to eq("\e[1mb\e[0m")
    end

    it "indents code blocks line by line" do
      ui.code("Customer\n  .count")

      expect(printed).to eq("  Customer\n    .count\n")
    end

    it "prints status lines with symbols" do
      ui.success("done")
      ui.failure("broken")
      ui.warn("careful")

      expect(printed).to include("✓ done", "✗ broken", "careful")
    end
  end
end
