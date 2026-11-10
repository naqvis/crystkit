require "./spec_helper"
require "../src/features/idle_monitor"

describe CrystKit::Features::IdleMonitor do
  it "reports idle duration from its provider" do
    monitor = CrystKit::Features::IdleMonitor.new(CrystKit::Test::FakeIdleProvider.new(6.minutes))
    monitor.idle_seconds.should eq(360)
    monitor.idle?.should be_true
  end

  it "reports active below the default threshold" do
    monitor = CrystKit::Features::IdleMonitor.new(CrystKit::Test::FakeIdleProvider.new(299.seconds))
    monitor.idle?.should be_false
  end

  it "delivers transitions and stops its provider" do
    provider = CrystKit::Test::FakeIdleProvider.new
    monitor = CrystKit::Features::IdleMonitor.new(provider)
    channel = monitor.start_monitor

    provider.change(true, 301)
    change = channel.receive
    change.idle?.should be_true
    change.seconds.should eq(301)

    monitor.stop_monitor
    provider.running?.should be_false
    channel.closed?.should be_true
  end

  it "closes the previous stream when restarted" do
    provider = CrystKit::Test::FakeIdleProvider.new
    monitor = CrystKit::Features::IdleMonitor.new(provider)
    previous = monitor.start_monitor
    current = monitor.start_monitor

    previous.closed?.should be_true
    provider.change(false, 2)
    current.receive.idle?.should be_false
  end

  it "coalesces an unread transition to the latest state" do
    provider = CrystKit::Test::FakeIdleProvider.new
    monitor = CrystKit::Features::IdleMonitor.new(provider)
    channel = monitor.start_monitor

    provider.change(true, 301)
    provider.change(false, 1)

    change = channel.receive
    change.idle?.should be_false
    change.seconds.should eq(1)
  end
end
