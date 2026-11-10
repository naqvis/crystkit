require "./spec_helper"
require "../../src/builder/scaffold/scaffold"

module CrystKit::Builder::Scaffold
  describe Resolver do
    it "uses app event handlers without manual frontend event declarations" do
      source = File.read(Path[__DIR__] / "../../src/builder/scaffold/hello/src/main.cr.ecr")

      source.should contain(%(app.on("frontend:ping")))
      source.should_not contain("declare_frontend_event")
    end

    it "copies dotfile templates and renders known template variables" do
      SpecHelpers.with_temp_dir do |dir|
        source = File.join(dir, "source")
        target = File.join(dir, "target")
        Dir.mkdir_p(File.join(source, "src"))

        File.write(File.join(source, ".gitignore.ecr"), "/lib\n")
        File.write(File.join(source, "src", "main.cr.ecr"), "puts <%= name %>\n")
        File.write(File.join(source, "crystkit.json.ecr"), %({"authors": [<%= author.empty? ? "" : author.to_json %>]}\n))

        Resolver.new.copy_external(source, target, "DemoApp", "com.demo.app", "0.1.0", "Ada")

        File.read(File.join(target, ".gitignore")).should eq("/lib\n")
        File.read(File.join(target, "src", "main.cr")).should eq("puts DemoApp\n")
        File.read(File.join(target, "crystkit.json")).should eq(%({"authors": ["Ada"]}\n))
      end
    end

    it "resolves a git-backed scaffold repository" do
      SpecHelpers.with_temp_dir do |dir|
        repo = File.join(dir, "repo")
        Dir.mkdir_p(repo)
        File.write(File.join(repo, "template.yml"), "name: remote\n")
        File.write(File.join(repo, "shard.yml.ecr"), "name: <%= name %>\n")

        Process.run("git", ["init"], chdir: repo, output: Process::Redirect::Close, error: Process::Redirect::Close).success?.should be_true
        Process.run("git", ["add", "."], chdir: repo, output: Process::Redirect::Close, error: Process::Redirect::Close).success?.should be_true
        Process.run("git", ["-c", "user.email=test@example.com", "-c", "user.name=Test", "commit", "-m", "fixture"], chdir: repo, output: Process::Redirect::Close, error: Process::Redirect::Close).success?.should be_true

        target = File.join(dir, "target")
        source = Resolver.new.resolve("file://#{repo}")
        source.should_not be_nil

        Resolver.new.copy_external(source.not_nil!, target, "RemoteApp", "com.remote.app", "0.1.0", "")

        File.read(File.join(target, "shard.yml")).should eq("name: RemoteApp\n")
      end
    end
  end
end
