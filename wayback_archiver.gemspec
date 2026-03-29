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
  spec.require_paths = ['lib']

  spec.required_ruby_version = '>= 3.1.0'

  spec.add_runtime_dependency 'logger'                     # No longer in default gems as of Ruby 4.0
  spec.add_runtime_dependency 'spidr',         '~> 0.7.1' # Crawl sites
  spec.add_runtime_dependency 'concurrent-ruby', '~> 1.3' # Concurrency primitives
  spec.add_runtime_dependency 'rexml',         '~> 3.3'
  spec.add_runtime_dependency 'rss',            '~> 0.3'      # RSS/Atom feed parsing
  spec.add_runtime_dependency 'csv'                           # CSV report output

  spec.add_development_dependency 'bundler',   '>= 2.1'
  spec.add_development_dependency 'rake',      '~> 13.0'
  spec.add_development_dependency 'rspec',     '~> 3.1'
  spec.add_development_dependency 'yard',      '~> 0.9'
  spec.add_development_dependency 'simplecov', '~> 0.22'
  spec.add_development_dependency 'webmock',   '~> 3.0'
end
