require 'spec_helper'

RSpec.describe 'wayback_archiver.gemspec' do
  let(:spec) do
    Gem::Specification.load(File.expand_path('../wayback_archiver.gemspec', __dir__))
  end

  # Regression: spec.executables was derived from a {bin,lib}/**/* glob, which
  # swept up bin/console and installed a generic `console` binary onto every
  # user's PATH (where it would fail anyway — it requires bundler/setup).
  it 'ships only the CLI as an executable' do
    expect(spec.executables).to eq(['wayback_archiver'])
  end

  it 'packages the README, changelog and license' do
    expect(spec.files).to include('README.md', 'CHANGELOG.md', 'LICENSE')
  end

  # The gemspec, the README and the CI matrix each stated a different
  # supported Ruby. CI is the only one that is actually tested, so it wins.
  it 'requires the oldest Ruby the CI matrix exercises' do
    require 'yaml'
    ci = YAML.safe_load_file(File.expand_path('../.github/workflows/ci.yml', __dir__))
    oldest = ci['jobs']['test']['strategy']['matrix']['ruby'].map(&:to_s).min_by(&:to_f)

    expect(spec.required_ruby_version.satisfied_by?(Gem::Version.new(oldest))).to eq(true)
    expect(spec.required_ruby_version.satisfied_by?(Gem::Version.new('3.2.0'))).to eq(false)
  end

  it 'agrees with the README on the required Ruby' do
    readme = File.read(File.expand_path('../README.md', __dir__))
    stated = readme[/Requires Ruby >= (\d+\.\d+)/, 1]

    expect(stated).not_to be_nil
    expect(spec.required_ruby_version.satisfied_by?(Gem::Version.new("#{stated}.0"))).to eq(true)
  end
end
