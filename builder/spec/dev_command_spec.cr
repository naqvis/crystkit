require "./spec_helper"
require "../../src/builder/commands/dev"

class CrystKit::Builder::Commands::Dev
  def spec_crystal_process=(process : Process?)
    @crystal_process = process
  end

  def spec_shutdown
    shutdown
  end
end

describe CrystKit::Builder::Commands::Dev do
  it "does not raise during shutdown when the Crystal child already exited" do
    command, args = SpecHelpers.test_cmd("exit", "0")
    process = Process.new(command, args)
    process.wait
    dev = CrystKit::Builder::Commands::Dev.new
    dev.spec_crystal_process = process
    dev.spec_shutdown
  end
end
