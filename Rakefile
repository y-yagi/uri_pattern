# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/test_*.rb"]
  t.warning = true
end

namespace :bench do
  desc "Report object-allocation counts for construction and matching"
  task :allocations do
    ruby "--yjit", "-Ilib", "benchmark/allocations.rb"
  end

  desc "Report throughput (iterations/sec) for construction and matching"
  task :ips do
    ruby "--yjit", "-Ilib", "benchmark/ips.rb"
  end
end

desc "Run allocation and throughput benchmarks"
task bench: %w[bench:allocations bench:ips]

task :download_wpt_resources do
  Dir.chdir "test/fixtures" do
    system("curl -O https://raw.githubusercontent.com/web-platform-tests/wpt/master/urlpattern/resources/urlpatterntestdata.json", exception: true)
  end
end

task default: :test
