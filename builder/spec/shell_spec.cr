require "./spec_helper"
require "../../src/builder/shell"

{% unless flag?(:win32) %}
  describe CrystKit::Builder::Shell do
    it "runs bash-style commands when bash is available" do
      if CrystKit::Builder::Shell.which?("bash")
        SpecHelpers.with_temp_dir do |dir|
          command = %q{set -- one two three; printf '%s\n' "${@: -1}" > last}
          CrystKit::Builder::Shell.run_with_shell(command, chdir: dir).should be_true
          File.read(File.join(dir, "last")).strip.should eq("three")
        end
      end
    end
  end
{% end %}
