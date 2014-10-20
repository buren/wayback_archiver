require 'bundler/gem_tasks'

task :default => :spec

# https://gist.github.com/buren-trialbee/f51c6d37ea96618bcc49
task :console do
  require 'irb'
  require 'irb/completion'
  require 'wayback_archiver'
  ARGV.clear
  IRB.start
end