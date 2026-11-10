require "./spec_helper"
require "../src/core/errors"
describe CrystKit::Core do
  describe "Error classes" do
    describe "Error" do
      it "creates a basic error" do
        error = CrystKit::Core::Error.new("test error")
        error.message.should eq("test error")
        error.code.should be_nil
        error.context.should be_nil
      end
      it "creates an error with code" do
        error = CrystKit::Core::Error.new("test error", code: "ERR001")
        error.message.should eq("test error")
        error.code.should eq("ERR001")
      end
      it "creates an error with context" do
        error = CrystKit::Core::Error.new("test error", context: "during initialization")
        error.message.should eq("test error")
        error.context.should eq("during initialization")
      end
      it "formats to_s with code and context" do
        error = CrystKit::Core::Error.new("test error", code: "ERR001", context: "init")
        str = error.to_s
        str.should contain("test error")
        str.should contain("ERR001")
        str.should contain("init")
      end
      it "can be raised and caught" do
        expect_raises(CrystKit::Core::Error, "test error") do
          raise CrystKit::Core::Error.new("test error")
        end
      end
    end
    describe "Specialized error classes" do
      it "creates IPCError" do
        error = CrystKit::Core::IPCError.new("IPC failed")
        error.should be_a(CrystKit::Core::Error)
        error.message.should eq("IPC failed")
      end
      it "creates PluginError" do
        error = CrystKit::Core::PluginError.new("Plugin failed")
        error.should be_a(CrystKit::Core::Error)
        error.message.should eq("Plugin failed")
      end
      it "creates SecurityError" do
        error = CrystKit::Core::SecurityError.new("Access denied")
        error.should be_a(CrystKit::Core::Error)
        error.message.should eq("Access denied")
      end
      it "creates FileSystemError" do
        error = CrystKit::Core::FileSystemError.new("File not found")
        error.should be_a(CrystKit::Core::Error)
        error.message.should eq("File not found")
      end
      it "creates NetworkError" do
        error = CrystKit::Core::NetworkError.new("Connection failed")
        error.should be_a(CrystKit::Core::Error)
        error.message.should eq("Connection failed")
      end
      it "can catch specific error types" do
        expect_raises(CrystKit::Core::IPCError) do
          raise CrystKit::Core::IPCError.new("IPC failed")
        end
      end
      it "can catch as base Error" do
        expect_raises(CrystKit::Core::Error) do
          raise CrystKit::Core::IPCError.new("IPC failed")
        end
      end
    end
    describe "TimeoutError" do
      it "creates a timeout error with operation and duration" do
        error = CrystKit::Core::TimeoutError.new("fetch_data", 30.seconds)
        message = error.message
        message.should_not be_nil
        message.not_nil!.should contain("fetch_data")
        message.not_nil!.should contain("30")
      end
      it "can be raised and caught" do
        expect_raises(CrystKit::Core::TimeoutError) do
          raise CrystKit::Core::TimeoutError.new("operation", 5.seconds)
        end
      end
    end
    describe "ValidationError" do
      it "creates a validation error" do
        error = CrystKit::Core::ValidationError.new("Invalid input")
        error.message.should eq("Invalid input")
        error.field.should be_nil
      end
      it "creates a validation error with field" do
        error = CrystKit::Core::ValidationError.new("Invalid email", field: "email")
        error.message.should eq("Invalid email")
        error.field.should eq("email")
      end
      it "can be raised and caught" do
        expect_raises(CrystKit::Core::ValidationError) do
          raise CrystKit::Core::ValidationError.new("Invalid input", field: "username")
        end
      end
    end
    describe "Error handling patterns" do
      it "uses nilable types for optional values" do
        result : String? = nil
        result.should be_nil
        result = "success"
        result.should eq("success")
      end
      it "uses exceptions for error conditions" do
        expect_raises(CrystKit::Core::Error, "operation failed") do
          raise CrystKit::Core::Error.new("operation failed")
        end
      end
      it "uses rescue for error handling" do
        result = begin
          raise CrystKit::Core::Error.new("error")
          "success"
        rescue ex : CrystKit::Core::Error
          "handled: #{ex.message}"
        end
        result.should eq("handled: error")
      end
      it "uses ensure for cleanup" do
        cleanup_called = false
        begin
          raise CrystKit::Core::Error.new("error")
        rescue
        ensure
          cleanup_called = true
        end
        cleanup_called.should be_true
      end
    end
  end
end
