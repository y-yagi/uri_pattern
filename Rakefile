# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/test_*.rb"]
  t.warning = true
end

task :download_wpt_resources do
  Dir.chdir "test/fixtures" do
    system("curl -O https://raw.githubusercontent.com/web-platform-tests/wpt/master/urlpattern/resources/urlpatterntestdata.json", exception: true)
  end
end

task default: :test
