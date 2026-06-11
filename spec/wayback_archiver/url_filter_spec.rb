require 'spec_helper'

RSpec.describe WaybackArchiver::URLFilter do
  describe '#match?' do
    it 'returns true when no filters are set' do
      filter = described_class.new
      expect(filter.match?('http://a.com/page')).to be true
    end

    it 'includes only matching extensions' do
      filter = described_class.new(include_ext: %w[pdf])
      expect(filter.match?('http://a.com/doc.pdf')).to be true
      expect(filter.match?('http://a.com/page')).to be false
      expect(filter.match?('http://a.com/img.png')).to be false
    end

    it 'excludes matching extensions' do
      filter = described_class.new(exclude_ext: %w[pdf png])
      expect(filter.match?('http://a.com/doc.pdf')).to be false
      expect(filter.match?('http://a.com/img.png')).to be false
      expect(filter.match?('http://a.com/page')).to be true
    end

    it 'applies include_ext then exclude_ext' do
      filter = described_class.new(include_ext: %w[pdf doc docx], exclude_ext: %w[docx])
      expect(filter.match?('http://a.com/a.pdf')).to be true
      expect(filter.match?('http://a.com/b.doc')).to be true
      expect(filter.match?('http://a.com/c.docx')).to be false
      expect(filter.match?('http://a.com/page')).to be false
    end

    it 'normalizes leading dots in extensions' do
      filter = described_class.new(include_ext: %w[.pdf])
      expect(filter.match?('http://a.com/doc.pdf')).to be true
      expect(filter.match?('http://a.com/page')).to be false
    end

    it 'is case-insensitive' do
      filter = described_class.new(include_ext: %w[pdf])
      expect(filter.match?('http://a.com/doc.PDF')).to be true
    end

    it 'handles query strings and fragments' do
      filter = described_class.new(include_ext: %w[pdf])
      expect(filter.match?('http://a.com/doc.pdf?v=1')).to be true
      expect(filter.match?('http://a.com/page#section')).to be false
    end
  end

  describe '#apply' do
    it 'returns all urls when no filters are set' do
      filter = described_class.new
      urls = %w[http://a.com/doc.pdf http://a.com/page]
      expect(filter.apply(urls)).to eq(urls)
    end

    it 'filters urls by extension' do
      filter = described_class.new(include_ext: %w[pdf])
      urls = %w[http://a.com/doc.pdf http://a.com/page http://a.com/img.png]
      expect(filter.apply(urls)).to eq(%w[http://a.com/doc.pdf])
    end

    it 'logs filtered count' do
      filter = described_class.new(exclude_ext: %w[png])
      urls = %w[http://a.com/doc.pdf http://a.com/img.png]

      expect(WaybackArchiver.logger).to receive(:info).with('Filtered 1 URL(s) by extension')
      filter.apply(urls)
    end

    it 'does not log when nothing is filtered' do
      filter = described_class.new(include_ext: %w[pdf])
      urls = %w[http://a.com/doc.pdf]

      expect(WaybackArchiver.logger).not_to receive(:info).with(/Filtered/)
      filter.apply(urls)
    end
  end
end
