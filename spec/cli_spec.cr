require "./spec_helper"
require "../src/features/cli"

module CrystKit::Features
  describe CLIParser do
    describe "argument parsing" do
      it "raises ValidationError for unknown options" do
        parser = CLIParser.new("myapp")
        expect_raises(Core::ValidationError) do
          parser.parse(["--unknown"])
        end
      end
      it "raises ValidationError for unexpected positional arguments" do
        parser = CLIParser.new("myapp")
        expect_raises(Core::ValidationError) do
          parser.parse(["unexpected"])
        end
      end
    end
    describe "boolean flags" do
      it "sets a boolean flag to true when present" do
        parser = CLIParser.new("myapp")
        parser.option("verbose", "Enable verbose output", OptionType::Bool)
        result = parser.parse(["--verbose"])
        result.get_bool("verbose").should be_true
      end
      it "defaults a boolean flag to false when absent" do
        parser = CLIParser.new("myapp")
        parser.option("verbose", "Enable verbose output", OptionType::Bool)
        result = parser.parse([] of String)
        result.get_bool("verbose").should be_false
      end
      it "handles multiple boolean flags independently" do
        parser = CLIParser.new("myapp")
        parser.option("debug", "Debug mode", OptionType::Bool)
        parser.option("quiet", "Quiet mode", OptionType::Bool)
        result = parser.parse(["--debug"])
        result.get_bool("debug").should be_true
        result.get_bool("quiet").should be_false
      end
    end
    describe "string arguments" do
      it "parses a string argument value" do
        parser = CLIParser.new("myapp")
        parser.option("name", "Application name", OptionType::String)
        result = parser.parse(["--name", "myapp"])
        result.get_string("name").should eq("myapp")
      end
      it "parses a string argument with spaces (as a single token)" do
        parser = CLIParser.new("myapp")
        parser.option("title", "Window title", OptionType::String)
        result = parser.parse(["--title", "Hello World"])
        result.get_string("title").should eq("Hello World")
      end
      it "raises ValidationError when a string option is missing its value" do
        parser = CLIParser.new("myapp")
        parser.option("name", "Application name", OptionType::String)
        expect_raises(Core::ValidationError) do
          parser.parse(["--name"])
        end
      end
      it "returns nil for an absent optional string argument" do
        parser = CLIParser.new("myapp")
        parser.option("name", "Application name", OptionType::String)
        result = parser.parse([] of String)
        result.get_string("name").should be_nil
      end
    end
    describe "numeric arguments" do
      it "parses an integer argument" do
        parser = CLIParser.new("myapp")
        parser.option("port", "Port number", OptionType::Int)
        result = parser.parse(["--port", "8080"])
        result.get_int("port").should eq(8080_i64)
      end
      it "parses a float argument" do
        parser = CLIParser.new("myapp")
        parser.option("scale", "Scale factor", OptionType::Float)
        result = parser.parse(["--scale", "1.5"])
        result.get_float("scale").should eq(1.5_f64)
      end
      it "raises ValidationError for a non-integer value on an Int option" do
        parser = CLIParser.new("myapp")
        parser.option("port", "Port number", OptionType::Int)
        expect_raises(Core::ValidationError) do
          parser.parse(["--port", "abc"])
        end
      end
      it "raises ValidationError for a non-numeric value on a Float option" do
        parser = CLIParser.new("myapp")
        parser.option("scale", "Scale factor", OptionType::Float)
        expect_raises(Core::ValidationError) do
          parser.parse(["--scale", "not-a-number"])
        end
      end
      it "parses negative integer values" do
        parser = CLIParser.new("myapp")
        parser.option("offset", "Offset value", OptionType::Int)
        result = parser.parse(["--offset", "-42"])
        result.get_int("offset").should eq(-42_i64)
      end
    end
    describe "argument aliases" do
      it "accepts a short flag alias" do
        parser = CLIParser.new("myapp")
        parser.option("verbose", "Enable verbose output", OptionType::Bool, short: "v")
        result = parser.parse(["-v"])
        result.get_bool("verbose").should be_true
      end
      it "accepts the long form when a short alias is defined" do
        parser = CLIParser.new("myapp")
        parser.option("verbose", "Enable verbose output", OptionType::Bool, short: "v")
        result = parser.parse(["--verbose"])
        result.get_bool("verbose").should be_true
      end
      it "stores the result under the long name regardless of which form is used" do
        parser = CLIParser.new("myapp")
        parser.option("port", "Port number", OptionType::Int, short: "p")
        result_short = parser.parse(["-p", "3000"])
        result_long = parser.parse(["--port", "3000"])
        result_short.get_int("port").should eq(3000_i64)
        result_long.get_int("port").should eq(3000_i64)
      end
      it "supports short alias for string options" do
        parser = CLIParser.new("myapp")
        parser.option("host", "Host to bind", OptionType::String, short: "H")
        result = parser.parse(["-H", "localhost"])
        result.get_string("host").should eq("localhost")
      end
      it "raises ValidationError for an unknown short flag" do
        parser = CLIParser.new("myapp")
        parser.option("verbose", "Enable verbose output", OptionType::Bool, short: "v")
        expect_raises(Core::ValidationError) do
          parser.parse(["-x"])
        end
      end
      it "includes both short and long forms in usage hint" do
        opt = Option.new("verbose", "Enable verbose output", OptionType::Bool, short: "v")
        opt.short_flag.should eq("-v")
        opt.long_flag.should eq("--verbose")
        opt.usage_hint.should contain("-v")
        opt.usage_hint.should contain("--verbose")
      end
    end
    describe "combined option parsing" do
      it "parses a mix of bool, string, and int options" do
        parser = CLIParser.new("myapp")
        parser.option("verbose", "Verbose", OptionType::Bool, short: "v")
        parser.option("host", "Host", OptionType::String, short: "H")
        parser.option("port", "Port", OptionType::Int, short: "p")
        result = parser.parse(["-v", "--host", "example.com", "-p", "9000"])
        result.get_bool("verbose").should be_true
        result.get_string("host").should eq("example.com")
        result.get_int("port").should eq(9000_i64)
      end
      it "generates help text containing option names" do
        parser = CLIParser.new("myapp", "A test application")
        parser.option("verbose", "Enable verbose output", OptionType::Bool, short: "v")
        parser.option("port", "Port number", OptionType::Int, short: "p")
        help = parser.help_text
        help.should contain("--verbose")
        help.should contain("--port")
        help.should contain("myapp")
      end
    end
  end
end
