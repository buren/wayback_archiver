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
end
