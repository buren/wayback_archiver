require 'spec_helper'

RSpec.describe WaybackArchiver::ArchiveResult do
  describe '#archived_url' do
    it 'returns the uri' do
      expect(described_class.new('buren').archived_url).to eq('buren')
    end
  end

  describe '#request_url' do
    it 'returns the correct uri' do
      response = Struct.new(:uri).new('buren')
      expect(described_class.new(nil, response).request_url).to eq('buren')
    end
  end

  describe '#code' do
    it 'returns the response code' do
      response = Struct.new(:code).new('buren')
      expect(described_class.new(nil, response).code).to eq('buren')
    end
  end

  describe '#errored?' do
    it 'returns true if errored' do
      expect(described_class.new(nil, nil, true).errored?).to eq(true)
    end
  end

  describe '#response?' do
    it 'returns the response code' do
      expect(described_class.new(nil, true).response).to eq(true)
    end
  end
end
