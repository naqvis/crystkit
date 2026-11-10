require "./spec_helper"
require "../src/features/biometric"

class FakeBiometricProvider < CrystKit::Features::BiometricAuth::Provider
  property? available : Bool
  property? reason_supported : Bool
  property? should_succeed : Bool
  property raise_on_auth : Exception?
  getter authenticate_calls : Array(String)

  def initialize(@available = true, @reason_supported = false, @should_succeed = true, @raise_on_auth = nil)
    @authenticate_calls = [] of String
  end

  def info : NativeDesktop::BiometricInfo
    NativeDesktop::BiometricInfo.new(
      @available,
      @available ? NativeDesktop::BiometricModality::Fingerprint : nil,
      @reason_supported,
    )
  end

  def authenticate(reason : String, window : NativeDesktop::Window?) : NativeDesktop::BiometricResult
    if ex = @raise_on_auth
      raise ex
    end
    @authenticate_calls << reason
    if @should_succeed
      NativeDesktop::BiometricResult.new(true)
    else
      NativeDesktop::BiometricResult.new(false, "user_canceled")
    end
  end
end

describe CrystKit::Features::BiometricAuth do
  describe "capability gating" do
    it "raises SecurityError when biometric:authenticate is not granted" do
      caps = CrystKit::Security::CapabilitySystem.new
      backend = FakeBiometricProvider.new
      auth = CrystKit::Features::BiometricAuth.new(backend, caps)

      expect_raises(CrystKit::Core::SecurityError, /biometric:authenticate/) do
        auth.authenticate("test")
      end
    end

    it "proceeds to backend when capability is granted" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("biometric:authenticate")
      backend = FakeBiometricProvider.new
      auth = CrystKit::Features::BiometricAuth.new(backend, caps)

      auth.authenticate("test")
      backend.authenticate_calls.size.should eq(1)
    end

    it "does not require capability for available? or modality" do
      caps = CrystKit::Security::CapabilitySystem.new
      backend = FakeBiometricProvider.new
      auth = CrystKit::Features::BiometricAuth.new(backend, caps)

      auth.available?.should be_true
      auth.modality.should eq(:fingerprint)
      auth.biometry_type.should eq(:fingerprint)
    end
  end

  describe "portable capability info" do
    it "reports normalized availability, modality, and prompt reason support" do
      backend = FakeBiometricProvider.new(reason_supported: true)
      auth = CrystKit::Features::BiometricAuth.new(backend)

      info = auth.info
      info.available?.should be_true
      info.modality.should eq("fingerprint")
      info.reason_supported?.should be_true
    end
  end

  describe "when no capability system is configured" do
    it "allows authenticate without capability check" do
      backend = FakeBiometricProvider.new
      auth = CrystKit::Features::BiometricAuth.new(backend)

      auth.authenticate("test")
      backend.authenticate_calls.size.should eq(1)
    end
  end

  describe "authentication flow" do
    it "returns success result when backend approves" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("biometric:authenticate")
      backend = FakeBiometricProvider.new(should_succeed: true)
      auth = CrystKit::Features::BiometricAuth.new(backend, caps)

      result = auth.authenticate("Unlock")
      result.success?.should be_true
      result.error.should be_nil
    end

    it "returns failure result with error when backend rejects" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("biometric:authenticate")
      backend = FakeBiometricProvider.new(should_succeed: false)
      auth = CrystKit::Features::BiometricAuth.new(backend, caps)

      result = auth.authenticate("Unlock")
      result.success?.should be_false
      result.error.should eq("user_canceled")
    end

    it "passes the reason string to the backend" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("biometric:authenticate")
      backend = FakeBiometricProvider.new
      auth = CrystKit::Features::BiometricAuth.new(backend, caps)

      auth.authenticate("Unlock your vault")
      backend.authenticate_calls.should eq(["Unlock your vault"])
    end
  end

  describe "backend error propagation" do
    it "propagates backend exceptions" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("biometric:authenticate")
      backend = FakeBiometricProvider.new
      backend.raise_on_auth = Exception.new("backend error")
      auth = CrystKit::Features::BiometricAuth.new(backend, caps)

      expect_raises(Exception, "backend error") do
        auth.authenticate("test")
      end
    end
  end
end
