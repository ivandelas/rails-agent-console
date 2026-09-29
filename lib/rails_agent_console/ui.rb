# frozen_string_literal: true

module RailsAgentConsole
  class UI
    COLORS = {
      black: 30, red: 31, green: 32, yellow: 33,
      blue: 34, magenta: 35, cyan: 36, white: 37, gray: 90
    }.freeze

    ROBOT = "\u{1F916}"
    WARNING = "\u26A0\uFE0F"
    CHECK = "\u2713"
    CROSS = "\u2717"

    def initialize(config = RailsAgentConsole.configuration)
      @config = config
    end

    def say(text = "")
      out.puts(text)
    end

    def blank
      out.puts
    end

    def heading(text)
      say "#{ROBOT} #{bold(text)}"
    end

    def note(text)
      say dim(text)
    end

    def success(text)
      say "#{colorize(CHECK, :green)} #{text}"
    end

    def failure(text)
      say "#{colorize(CROSS, :red)} #{text}"
    end

    def warn(text)
      say "#{WARNING}  #{colorize(text, :yellow)}"
    end

    def code(source)
      source.to_s.each_line do |line|
        say "  #{colorize(line.chomp, :cyan)}"
      end
    end

    def tree(lines)
      lines.each { |line| say "  #{dim(line)}" }
    end

    def ask(question, default: nil)
      out.print("#{question} ")
      out.flush
      answer = read_line
      return default if answer.nil? || answer.strip.empty?

      answer.strip
    end

    def yes?(question, default: false)
      suffix = default ? "[Y/n]" : "[y/N]"
      answer = ask("#{question} #{suffix}", default: nil)
      return default if answer.nil?

      case answer.downcase
      when "y", "yes" then true
      when "n", "no", "" then false
      else default
      end
    end

    def secret(question)
      out.print("#{question} ")
      out.flush
      value = read_secret
      out.puts
      value.to_s.strip
    end

    def bold(text)
      @config.color? ? "\e[1m#{text}\e[0m" : text.to_s
    end

    def dim(text)
      @config.color? ? "\e[2m#{text}\e[0m" : text.to_s
    end

    def colorize(text, color)
      return text.to_s unless @config.color?

      "\e[#{COLORS.fetch(color, 37)}m#{text}\e[0m"
    end

    private

    def out
      @config.out
    end

    def read_line
      @config.in.gets
    end

    def read_secret
      input = @config.in
      require "io/console"

      return input.gets.to_s.chomp unless echo_controllable?(input)

      input.noecho { input.gets.to_s.chomp }
    rescue LoadError, Errno::ENOTTY, Errno::ENODEV
      input.gets.to_s.chomp
    end

    def echo_controllable?(input)
      input.respond_to?(:noecho) && input.respond_to?(:tty?) && input.tty?
    end
  end
end
