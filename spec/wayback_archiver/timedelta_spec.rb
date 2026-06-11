require 'spec_helper'
require 'wayback_archiver/timedelta'

RSpec.describe WaybackArchiver::Timedelta do
  describe '.parse' do
    it 'parses days' do
      expect(described_class.parse('3d')).to eq(259_200)
    end

    it 'parses hours' do
      expect(described_class.parse('5h')).to eq(18_000)
    end

    it 'parses minutes' do
      expect(described_class.parse('20m')).to eq(1_200)
    end

    it 'parses seconds' do
      expect(described_class.parse('30s')).to eq(30)
    end

    it 'parses bare number as seconds' do
      expect(described_class.parse('120')).to eq(120)
    end

    it 'parses compound expression' do
      expect(described_class.parse('3d 5h 20m')).to eq(278_400)
    end

    it 'parses without spaces between components' do
      expect(described_class.parse('1d12h')).to eq(129_600)
    end

    it 'is case insensitive' do
      expect(described_class.parse('1D 2H 3M')).to eq(93_780)
    end

    it 'raises on empty string' do
      expect { described_class.parse('') }.to raise_error(ArgumentError, /Empty/)
    end

    it 'raises on invalid format' do
      expect { described_class.parse('abc') }.to raise_error(ArgumentError, /Invalid timedelta/)
    end
  end

  describe '.to_cdx_timestamp' do
    it 'returns a 14-digit timestamp string' do
      ts = described_class.to_cdx_timestamp('7d')
      expect(ts).to match(/\A\d{14}\z/)
    end

    it 'returns a timestamp in the past' do
      ts = described_class.to_cdx_timestamp('1d')
      parsed = Time.strptime(ts, '%Y%m%d%H%M%S')
      expect(parsed).to be < Time.now
      expect(parsed).to be > Time.now - 90_000 # ~25 hours tolerance
    end
  end
end
