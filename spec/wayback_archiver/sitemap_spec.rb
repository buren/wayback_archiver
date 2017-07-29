require 'spec_helper'

RSpec.describe WaybackArchiver::Sitemap do
  describe '#new' do
    it 'raises error REXML::ParseException when strict mode is true' do
      expect do
        described_class.new('<wat></wat><man></man>', strict: true)
      end.to raise_error(REXML::ParseException)
    end

    it 'if strict mode false it swallows XML errors' do
      sitemap = described_class.new('<buren></buren><stam></stam>')
      expect(sitemap.urls).to be_empty
    end
  end

  describe '#urls' do
    it 'returns URLs in XML sitemap' do
      sitemap = described_class.new(File.read('spec/data/sitemap.xml'))
      expect(sitemap.urls).to eq(%w[http://www.example.com/])
    end

    it 'returns URLs in plain text sitemap' do
      file = "http://www.example.com/\nhttp://www.example.com/path"
      sitemap = described_class.new(file)
      expected = %w[
        http://www.example.com/
        http://www.example.com/path
      ]
      expect(sitemap.urls).to eq(expected)
    end

    it 'returns empty array when passed empty document' do
      sitemap = described_class.new('')
      expect(sitemap.urls).to be_empty
    end
  end

  describe '#sitemaps' do
    it 'returns sitemap URLs in sitemap' do
      sitemap = described_class.new(File.read('spec/data/sitemap_index.xml'))
      expected = %w[
        http://www.example.com/sitemap1.xml.gz
        http://www.example.com/sitemap2.xml.gz
      ]
      expect(sitemap.sitemaps).to eq(expected)
    end

    it 'returns empty array when passed empty document' do
      sitemap = described_class.new('')
      expect(sitemap.sitemaps).to be_empty
    end
  end

  describe '#plain_document?' do
    it 'returns true when passed non-XML document' do
      sitemap = described_class.new('')
      expect(sitemap.plain_document?).to eq(true)
    end

    it 'returns false when passed XML document' do
      sitemap = described_class.new('<buren></buren>')
      expect(sitemap.plain_document?).to eq(false)
    end
  end

  describe '#root_name' do
    it 'returns nil when passed non-XML document' do
      sitemap = described_class.new('')
      expect(sitemap.root_name).to be_nil
    end

    it 'returns root name when passed XML document' do
      sitemap = described_class.new('<buren></buren>')
      expect(sitemap.root_name).to eq('buren')
    end
  end

  describe '#sitemap_index?' do
    it 'returns true if document is a sitemap index' do
      sitemap = described_class.new(File.read('spec/data/sitemap_index.xml'))
      expect(sitemap.sitemap_index?).to eq(true)
    end

    it 'returns false if document sitemap' do
      sitemap = described_class.new(File.read('spec/data/sitemap.xml'))
      expect(sitemap.sitemap_index?).to eq(false)
    end
  end

  describe '#urlset?' do
    it 'returns true if document is a sitemap' do
      sitemap = described_class.new(File.read('spec/data/sitemap.xml'))
      expect(sitemap.urlset?).to eq(true)
    end

    it 'returns false if document is a sitemap index' do
      sitemap = described_class.new(File.read('spec/data/sitemap_index.xml'))
      expect(sitemap.urlset?).to eq(false)
    end
  end
end
