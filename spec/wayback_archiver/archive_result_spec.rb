require 'spec_helper'

RSpec.describe WaybackArchiver::ArchiveResult do
  describe '#archived_url' do
    it 'returns the uri' do
      expect(described_class.new('buren').archived_url).to eq('buren')
    end
  end

  describe '#errored?' do
    it 'returns true if errored' do
      expect(described_class.new(nil, error: true).errored?).to eq(true)
    end
  end
end
