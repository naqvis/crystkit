require "../core/errors"

module CrystKit
  module Features
    # Supported option value types.
    #
    # `Bool` is special-cased: boolean options act as flags and do not
    # consume the next token on the command line. The other variants each
    # take a value argument that is parsed via `String#to_i64` / `to_f64`.
    #
    # Requirement 23.2, 23.3, 23.4
    enum OptionType
      Bool
      String
      Int
      Float
    end

    # A single parsed argument value, which may be a bool, string, int, or float.
    #
    # The union mirrors the `OptionType` enum so a parsed value can be
    # narrowed at runtime via `#as?` without losing type information.
    #
    # Requirement 23.2, 23.3, 23.4
    alias OptionValue = ::Bool | ::String | Int64 | Float64

    # Holds the result of a successful parse: the matched subcommand name (if any)
    # and a map of option name → value.
    #
    # `ParsedArgs` is immutable; the underlying values map is owned by the
    # parser result and not shared with the parser's internal state, so it
    # is safe to retain a `ParsedArgs` instance beyond the parser lifetime.
    #
    # Requirement 23.1, 23.8
    class ParsedArgs
      getter subcommand : ::String?
      @values : Hash(::String, OptionValue)

      # Creates a result wrapping *subcommand* (the matched subcommand name
      # or `nil` for a bare invocation) and the *values* map of option name
      # to typed value.
      def initialize(@subcommand : ::String?, @values : Hash(::String, OptionValue))
      end

      # Return the raw `OptionValue` union for *name*, or `nil` if the
      # option was not set and had no default.
      def get(name : ::String) : OptionValue?
        @values[name]?
      end

      # Return the value as a `String`, or `nil` if the option was absent
      # or stored as a different type.
      def get_string(name : ::String) : ::String?
        v = @values[name]?
        v.as?(::String)
      end

      # Return the value as an `Int64`, or `nil` if the option was absent
      # or stored as a different type.
      def get_int(name : ::String) : Int64?
        v = @values[name]?
        v.as?(Int64)
      end

      # Return the value as a `Float64`, or `nil` if the option was absent
      # or stored as a different type.
      def get_float(name : ::String) : Float64?
        v = @values[name]?
        v.as?(Float64)
      end

      # Return the value as a Bool (defaults to false when absent).
      #
      # Requirement 23.2
      def get_bool(name : ::String) : ::Bool
        v = @values[name]?
        v.as?(::Bool) || false
      end

      # Return all option names that were set, either by flag, environment
      # variable fallback, or default value application.
      def keys : Array(::String)
        @values.keys
      end
    end

    # Describes a single command-line option (flag or value argument).
    #
    # An `Option` is the static description of an accepted flag; the parsed
    # value lives in `ParsedArgs`. Options are identified by their *name*
    # (the long form without dashes) and optionally by a one-character
    # *short* alias.
    class Option
      getter name : ::String
      getter short : ::String?
      getter description : ::String
      getter type : OptionType
      getter? required : ::Bool
      getter default : OptionValue?
      getter env_var : ::String?

      # Creates an option descriptor.
      #
      # - *name*: long form name without leading dashes (e.g. `"verbose"`).
      # - *description*: human-readable summary used in generated help text.
      # - *type*: value type; `Bool` options are flags.
      # - *short*: optional single-character alias (without the dash).
      # - *required*: when `true`, parsing raises if the option is missing.
      # - *default*: value used when the option is absent and no env var
      #   applies.
      # - *env_var*: optional environment variable name consulted before
      #   flag parsing so deployments can inject configuration without
      #   modifying argv.
      def initialize(
        @name : ::String,
        @description : ::String,
        @type : OptionType,
        @short = nil,
        @required = false,
        @default = nil,
        @env_var = nil,
      )
      end

      # The long flag form, e.g. `"--verbose"`.
      def long_flag : ::String
        "--#{name}"
      end

      # The short flag form, e.g. `"-v"`, or `nil` when no alias is defined.
      #
      # Requirement 23.5
      def short_flag : ::String?
        short ? "-#{short}" : nil
      end

      # One-line usage hint for help text.
      #
      # Combines long and short flags (e.g. `"--verbose, -v"`) and appends
      # an uppercased placeholder for non-bool value options
      # (e.g. `"--port, -p PORT"`).
      def usage_hint : ::String
        flag = long_flag
        flag += ", #{short_flag}" if short_flag
        case type
        when OptionType::Bool
          flag
        else
          "#{flag} <#{name.upcase}>"
        end
      end
    end

    # A subcommand with its own set of options and an optional handler.
    #
    # Subcommands are detected by the parser when the first non-flag token
    # matches a registered name; their options are then merged with the
    # global options for the duration of the parse. A subcommand may carry
    # a handler block invoked with the final `ParsedArgs` after a
    # successful parse.
    #
    # Requirement 23.8
    class Subcommand
      getter name : ::String
      getter description : ::String
      getter options : Array(Option)
      getter handler : (ParsedArgs ->)?

      # Creates an empty subcommand with no options and no handler.
      def initialize(@name : ::String, @description : ::String)
        @options = [] of Option
        @handler = nil
      end

      # Add an option to this subcommand.
      #
      # Arguments mirror `Option#initialize` and are forwarded verbatim.
      def option(
        name : ::String,
        description : ::String,
        type : OptionType,
        short : ::String? = nil,
        required : ::Bool = false,
        default : OptionValue? = nil,
        env_var : ::String? = nil,
      ) : Nil
        @options << Option.new(name, description, type, short, required, default, env_var)
      end

      # Register a handler block that is called when this subcommand is parsed.
      #
      # The block receives the `ParsedArgs` produced by the parse — including
      # global options — and is invoked *after* required-option validation
      # has succeeded but *before* `CLIParser#parse` returns to its caller.
      # Exceptions raised by the block propagate out of `#parse`.
      def run(&block : ParsedArgs ->) : Nil
        @handler = block
      end

      # Generate help text for this subcommand.
      #
      # *program_name* is the basename used in the `Usage:` line so the
      # generated text matches the user's invocation.
      def help_text(program_name : ::String) : ::String
        lines = [] of ::String
        lines << "Usage: #{program_name} #{name} [options]"
        lines << ""
        lines << description
        unless options.empty?
          lines << ""
          lines << "Options:"
          options.each { |opt| lines << "  #{opt.usage_hint.ljust(30)} #{opt.description}" }
        end
        lines.join("\n")
      end
    end

    # `CLIParser` provides command-line argument parsing with support for
    # boolean flags, string/numeric arguments, short and long aliases,
    # required and optional arguments with defaults, environment-variable
    # fallbacks, and named subcommands with their own option sets and
    # handlers.
    #
    # Parsing proceeds in four phases:
    #
    # 1. *Subcommand detection* — the first non-flag token is matched
    #    against registered subcommand names; if matched, it is consumed
    #    and its options are merged into the active option set.
    # 2. *Environment defaults* — for each active option with an `env_var`,
    #    the corresponding `ENV` value is parsed and stored unless a flag
    #    later overrides it.
    # 3. *Flag parsing* — long (`--name`) and short (`-n`) tokens are
    #    consumed; boolean flags set the option to `true`, value options
    #    consume the next token. `--help` / `-h` raise a
    #    `Core::ValidationError` whose message is the help text.
    # 4. *Defaults & validation* — unset options fall back to their
    #    declared default (with `false` for booleans), then required
    #    options are checked and a missing one raises.
    #
    # On success the matched subcommand's handler (if any) is invoked with
    # the `ParsedArgs`, and the result is returned to the caller.
    #
    # Example:
    #
    # ```
    # parser = CrystKit::Features::CLIParser.new("myapp", "My application")
    # parser.option("verbose", "Enable verbose output", OptionType::Bool, short: "v")
    # parser.option("port", "Port number", OptionType::Int, short: "p", default: 8080_i64)
    # parser.command("serve", "Start the server") do |cmd|
    #   cmd.option("host", "Host to bind", OptionType::String, default: "localhost")
    # end
    # result = parser.parse(ARGV)
    # ```
    class CLIParser
      @program_name : ::String
      @description : ::String
      @global_options : Array(Option)
      @subcommands : Hash(::String, Subcommand)

      # Creates a new parser for a program named *program_name* with an
      # optional top-level *description* used in generated help text.
      #
      # The parser starts with no global options and no subcommands; use
      # `#option` and `#command` to populate it before calling `#parse`.
      def initialize(@program_name : ::String, @description = "")
        @global_options = [] of Option
        @subcommands = Hash(::String, Subcommand).new
      end

      # Add a global option (applies to all invocations, before any subcommand).
      #
      # Global options are accepted both with and without a subcommand on
      # the command line. The arguments mirror `Option#initialize`.
      def option(
        name : ::String,
        description : ::String,
        type : OptionType,
        short : ::String? = nil,
        required : ::Bool = false,
        default : OptionValue? = nil,
        env_var : ::String? = nil,
      ) : Nil
        @global_options << Option.new(name, description, type, short, required, default, env_var)
      end

      # Define a subcommand. The block receives a `Subcommand` instance where
      # per-subcommand options and a handler can be registered.
      #
      # The subcommand is stored by *name*; duplicate names overwrite the
      # earlier registration.
      #
      # Requirement 23.8
      def command(name : ::String, description : ::String, & : Subcommand ->) : Nil
        cmd = Subcommand.new(name, description)
        yield cmd
        @subcommands[name] = cmd
      end

      # Parse *args* (typically `ARGV`) and return a `ParsedArgs` on success,
      # or raise `Core::ValidationError` on invalid input.
      #
      # The parse implements the four-phase pipeline described in the class
      # documentation. `--help` / `-h` are detected at any position and
      # raise a `ValidationError` whose message is the appropriate help
      # text — this lets the top-level caller distinguish "user asked for
      # help" from "user made a mistake" via the error's `field` value
      # (`"help"` vs the offending option/argument name).
      def parse(args : Array(::String)) : ParsedArgs
        tokens = args.dup
        values = Hash(::String, OptionValue).new
        subcommand_name : ::String? = nil
        active_options = @global_options

        # Detect subcommand as the first non-flag token.
        if !tokens.empty? && !tokens.first.starts_with?("-")
          candidate = tokens.first
          if @subcommands.has_key?(candidate)
            subcommand_name = candidate
            tokens.shift
            active_options = @global_options + @subcommands[candidate].options
          end
        end

        # Apply environment variable defaults before parsing flags.
        apply_env_defaults(active_options, values)

        # Parse tokens.
        i = 0
        while i < tokens.size
          token = tokens[i]

          if token == "--help" || token == "-h"
            raise Core::ValidationError.new(help_text(subcommand_name), "help")
          end

          if token.starts_with?("--")
            key = token[2..]
            opt = find_option(active_options, long: key)
            raise Core::ValidationError.new("Unknown option: #{token}\n\n#{help_text(subcommand_name)}", "option") unless opt

            if opt.type == OptionType::Bool
              values[opt.name] = true
            else
              i += 1
              raise Core::ValidationError.new("Option #{token} requires a value", opt.name) if i >= tokens.size
              values[opt.name] = parse_value(opt, tokens[i])
            end
          elsif token.starts_with?("-") && token.size > 1
            short_key = token[1..]
            opt = find_option(active_options, short: short_key)
            raise Core::ValidationError.new("Unknown option: #{token}\n\n#{help_text(subcommand_name)}", "option") unless opt

            if opt.type == OptionType::Bool
              values[opt.name] = true
            else
              i += 1
              raise Core::ValidationError.new("Option #{token} requires a value", opt.name) if i >= tokens.size
              values[opt.name] = parse_value(opt, tokens[i])
            end
          else
            raise Core::ValidationError.new("Unexpected argument: #{token}\n\n#{help_text(subcommand_name)}", "argument")
          end

          i += 1
        end

        # Apply defaults for options not yet set.
        apply_defaults(active_options, values)

        # Validate required options.
        validate_required(active_options, values, subcommand_name)

        result = ParsedArgs.new(subcommand_name, values)

        # Invoke subcommand handler if registered.
        if name = subcommand_name
          if sub = @subcommands[name]?
            sub.handler.try(&.call(result))
          end
        end

        result
      end

      # Generate top-level help text.
      #
      # When *subcommand_name* is given and matches a registered subcommand,
      # returns that subcommand's help text; otherwise returns the
      # program-level usage listing global options and a one-line summary of
      # each registered subcommand.
      #
      # Requirement 23.9
      def help_text(subcommand_name : ::String? = nil) : ::String
        if name = subcommand_name
          if sub = @subcommands[name]?
            return sub.help_text(@program_name)
          end
        end

        lines = [] of ::String
        lines << "Usage: #{@program_name}"
        lines << "  #{@program_name} [options]" if @subcommands.empty?
        lines << "  #{@program_name} <command> [options]" unless @subcommands.empty?
        lines << ""
        lines << @description unless @description.empty?

        unless @global_options.empty?
          lines << ""
          lines << "Options:"
          @global_options.each { |opt| lines << "  #{opt.usage_hint.ljust(30)} #{opt.description}" }
        end

        unless @subcommands.empty?
          lines << ""
          lines << "Commands:"
          @subcommands.each_value { |sub_cmd| lines << "  #{sub_cmd.name.ljust(20)} #{sub_cmd.description}" }
          lines << ""
          lines << "Run '#{@program_name} <command> --help' for more information on a command."
        end

        lines.join("\n")
      end

      # Private helpers

      # :nodoc:
      private def find_option(options : Array(Option), long : ::String? = nil, short : ::String? = nil) : Option?
        options.find do |opt|
          (long && opt.name == long) || (short && opt.short == short)
        end
      end

      # Parse a raw string token into the typed `OptionValue` expected by *opt*.
      #
      # Raises `Core::ValidationError` (with the option name as `field`)
      # when the value cannot be coerced to the declared type.
      private def parse_value(opt : Option, raw : ::String) : OptionValue
        case opt.type
        when OptionType::String
          raw
        when OptionType::Int
          begin
            raw.to_i64
          rescue
            raise Core::ValidationError.new(
              "Option --#{opt.name} expects an integer, got: #{raw}", opt.name
            )
          end
        when OptionType::Float
          begin
            raw.to_f64
          rescue
            raise Core::ValidationError.new(
              "Option --#{opt.name} expects a number, got: #{raw}", opt.name
            )
          end
        else
          # Bool options are handled before calling parse_value; this branch
          # should never be reached.
          raw
        end
      end

      # Apply environment variable fallbacks before flag parsing.
      #
      # For each option with an `env_var` set, parses the corresponding
      # `ENV` value into the *values* map unless a value is already present.
      # Unparseable environment values are silently ignored so that
      # required-option validation surfaces the problem later with a clearer
      # message.
      #
      # Requirement 23.11
      private def apply_env_defaults(options : Array(Option), values : Hash(::String, OptionValue)) : Nil
        options.each do |opt|
          next unless env_key = opt.env_var
          next if values.has_key?(opt.name)
          env_val = ENV[env_key]?
          next unless env_val
          begin
            values[opt.name] = parse_value(opt, env_val)
          rescue
            # Silently ignore unparseable env values; validation will catch
            # missing required options later.
          end
        end
      end

      # Apply default values for options that were not set by flags or env vars.
      #
      # Boolean options always end up with a value (`false` when absent and
      # no default is declared) so that downstream `get_bool` never sees a
      # missing key. Other types only get a value when an explicit `default`
      # was declared.
      #
      # Requirement 23.7
      private def apply_defaults(options : Array(Option), values : Hash(::String, OptionValue)) : Nil
        options.each do |opt|
          next if values.has_key?(opt.name)
          if default = opt.default
            values[opt.name] = default
          elsif opt.type == OptionType::Bool
            # Boolean flags default to false when absent.
            values[opt.name] = false
          end
        end
      end

      # Raise `ValidationError` for any required option that has no value.
      #
      # The error message embeds the full help text so the user sees usage
      # hints alongside the missing-option diagnostic.
      #
      # Requirement 23.6
      private def validate_required(options : Array(Option), values : Hash(::String, OptionValue), subcommand_name : ::String?) : Nil
        options.each do |opt|
          next unless opt.required?
          next if values.has_key?(opt.name)
          raise Core::ValidationError.new(
            "Required option --#{opt.name} is missing\n\n#{help_text(subcommand_name)}",
            opt.name
          )
        end
      end
    end
  end
end
