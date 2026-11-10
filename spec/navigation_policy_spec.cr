require "./spec_helper"
require "../src/features/navigation_policy"

describe CrystKit::Features::NavigationPolicy do
  it "allows by default" do
    np = CrystKit::Features::NavigationPolicy.new
    np.evaluate("https://example.com").should eq(CrystKit::Features::NavigationPolicy::Decision::Allow)
  end

  it "invokes custom handler" do
    np = CrystKit::Features::NavigationPolicy.new
    np.on_navigation { |_| CrystKit::Features::NavigationPolicy::Decision::Deny }
    np.evaluate("https://example.com").should eq(CrystKit::Features::NavigationPolicy::Decision::Deny)
  end

  it "allows external URLs with custom handler" do
    np = CrystKit::Features::NavigationPolicy.new
    np.on_navigation { |_| CrystKit::Features::NavigationPolicy::Decision::External }
    np.evaluate("https://evil.com").should eq(CrystKit::Features::NavigationPolicy::Decision::External)
  end

  it "clears the handler" do
    np = CrystKit::Features::NavigationPolicy.new
    np.on_navigation { |_| CrystKit::Features::NavigationPolicy::Decision::Deny }
    np.clear
    np.evaluate("https://example.com").should eq(CrystKit::Features::NavigationPolicy::Decision::Allow)
  end
end
