# Info at https://github.com/guard/guard#readme
guard :rspec, cmd: 'bundle exec rspec', all_on_start: true, all_after_pass: false  do
  watch(%r{^spec/.+_spec\.rb$}) # Run specs in spec file on change

  # Watch spec support & config files
  watch(%r{^spec/support/(.+)\.rb$}) { 'spec' }
  watch('spec/spec_helper.rb')       { 'spec' }

  # Watch lib/omorfia
  watch(%r{^lib/wayback_archiver/(.+)\.rb$}) { |m| "spec/wayback_archiver/#{m[1]}_spec.rb" }
end
