# coding: utf-8

lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'wayback_archiver/version'

Gem::Specification.new do |spec|
  spec.name          = 'wayback_archiver'
  spec.version       = WaybackArchiver::VERSION
  spec.authors       = ['Jacob Burenstam']
  spec.email         = ['burenstam@gmail.com']

  spec.summary       = 'Post URLs to Wayback Machine (Internet Archive)'
  spec.description   = 'Post URLs to Wayback Machine (Internet Archive), using a crawler, from Sitemap(s) or a list of URLs.'
  spec.homepage      = 'https://github.com/buren/wayback_archiver'
  spec.license       = 'MIT'

  spec.files         = Dir.glob('{bin,lib}/**/*')
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ['lib']

  spec.required_ruby_version = '>= 2.0.0'

  spec.add_runtime_dependency 'spidr',         '~> 0.7.1' # Crawl sites
  spec.add_runtime_dependency 'concurrent-ruby', '~> 1.3' # Concurrency primitivies
  spec.add_runtime_dependency 'rexml',         '~> 3.3.9'

  spec.add_development_dependency 'bundler',   '~> 2.1'
  spec.add_development_dependency 'rake',      '~> 12.3'
  spec.add_development_dependency 'rspec',     '~> 3.1'
  spec.add_development_dependency 'yard',      '~> 0.9'
  spec.add_development_dependency 'simplecov', '~> 0.14.1'
  spec.add_development_dependency 'coveralls', '~> 0.8'
  spec.add_development_dependency 'redcarpet', '~> 3.2'
  spec.add_development_dependency 'webmock', '~> 3.0'
  spec.add_development_dependency 'byebug', '~> 11.1.3'
end
