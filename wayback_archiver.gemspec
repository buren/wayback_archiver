# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'wayback_archiver/version'

Gem::Specification.new do |spec|
  spec.name          = 'wayback_archiver'
  spec.version       = WaybackArchiver::VERSION
  spec.authors       = ['Jacob Burenstam']
  spec.email         = ['burenstam@gmail.com']

  spec.summary       = %q{Send URLs to Wayback Machine}
  spec.description   = %q{Send URLs to Wayback Machine. From: sitemap, file or single URL.}
  spec.homepage      = 'https://github.com/buren/wayback_archiver'
  spec.license       = 'MIT'

  spec.add_dependency 'nokogiri'
  spec.files         = Dir.glob("{bin,lib}/**/*")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ['lib']

  spec.add_development_dependency 'bundler', '~> 1.3'
  spec.add_development_dependency 'rake'
end
