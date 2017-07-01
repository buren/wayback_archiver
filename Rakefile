require 'bundler/gem_tasks'

task default: :spec

task :console do
  require 'irb'
  require 'irb/completion'
  require 'wayback_archiver'
  ARGV.clear
  IRB.start
end
