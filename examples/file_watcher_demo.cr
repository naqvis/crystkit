require "../src/features/file_watcher"
require "file_utils"
require "set"

tmpdir = File.join(Dir.tempdir, "crystkit-file_watcher-demo")
FileUtils.rm_rf(tmpdir)
FileUtils.mkdir_p(tmpdir)

watcher = CrystKit::Features::FileWatcher.new
channel = watcher.watch(tmpdir)

expected = {"created", "modified", "removed"}
seen = Set(String).new

spawn do
  sleep 1.second
  File.write("#{tmpdir}/hello.txt", "hello world")
  sleep 0.8.seconds
  File.write("#{tmpdir}/hello.txt", "modified content")
  sleep 0.8.seconds
  File.delete("#{tmpdir}/hello.txt")
end

puts "Watching #{tmpdir} ..."
loop do
  event = channel.receive?
  break unless event
  puts "  #{event.type}: #{File.basename(event.path)}"
  seen << event.type
  break if expected.all? { |t| seen.includes?(t) }
end

watcher.close
FileUtils.rm_rf(tmpdir)
puts "Done — received #{seen.size}/#{expected.size} event type(s): #{seen.join(", ")}"

exit expected.all? { |t| seen.includes?(t) } ? 0 : 1
