# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'wayback_archiver/version'

Gem::Specification.new do |spec|
  spec.name          = 'wayback_archiver'
  spec.version       = WaybackArchiver::VERSION
  spec.authors       = ['Jacob Burenstam']
  spec.email         = ['burenstam@gmail.com']

  spec.summary       = 'Send URLs to Wayback Machine'
  spec.description   = 'Send URLs to Wayback Machine. By crawling, sitemap, file or single URL.'
  spec.homepage      = 'https://github.com/buren/wayback_archiver'
  spec.license       = 'MIT'

  spec.files         = Dir.glob('{bin,lib}/**/*')
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ['lib']

  spec.required_ruby_version = '>= 1.9.3'

  spec.add_runtime_dependency 'site_mapper',   '~> 0'
  spec.add_runtime_dependency 'url_resolver',  '~> 0.1'

  spec.add_development_dependency 'bundler',   '~> 1.3'
  spec.add_development_dependency 'rake',      '~> 10.3'
  spec.add_development_dependency 'rspec',     '~> 3.1'
  spec.add_development_dependency 'yard',      '~> 0.8'
  spec.add_development_dependency 'coveralls', '~> 0.7'
  spec.add_development_dependency 'redcarpet', '~> 3.2'
end
