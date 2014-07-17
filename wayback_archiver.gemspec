# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'wayback_archiver/version'

Gem::Specification.new do |spec|
  spec.name          = 'wayback_archiver'
  spec.version       = WaybackArchiver::VERSION

  spec.required_rubygems_version = Gem::Requirement.new('>= 0') if spec.respond_to? :required_rubygems_version=
  spec.authors       = ['Jacob Burenstam']
  spec.email         = ['burenstam@gmail.com']
  spec.summary       = %q{Send URLs to Wayback Machine}
  spec.description   = %q{Send URLs to Wayback Machine. From: sitemap, file or single URL.}
  spec.homepage      = 'https://github.com/buren/wayback_archiver'
  spec.license       = 'MIT'

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ['lib']

  if spec.respond_to? :specification_version then
    spec.specification_version = 3

    if Gem::Version.new(Gem::VERSION) >= Gem::Version.new('1.2.0') then
    else
    end
  else
  end

  spec.add_development_dependency 'bundler', '~> 1.3'
  spec.add_development_dependency 'rake'
end
