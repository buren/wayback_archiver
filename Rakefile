require 'bundler/gem_tasks'

task default: :spec

task :console do
  require 'bundler/setup'
  require 'irb'
  require 'wayback_archiver'
  ARGV.clear
  IRB.start
end

task :spec do
  begin
    require 'rspec/core/rake_task'
    RSpec::Core::RakeTask.new(:spec)
  rescue LoadError
    puts 'Could *not* load rspec'
  end
end
