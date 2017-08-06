require 'spec_helper'

RSpec.describe WaybackArchiver do
  describe '::archive' do
    it 'raises ArgumentError when passed unknown strategy' do
      expect do
        described_class.archive('http://example.com', strategy: :watman_strategy)
      end.to raise_error(ArgumentError)
    end

    it 'calls ::auto when no strategy is given' do
      allow(described_class).to receive(:auto).and_return([])
      described_class.archive('http://example.com')
      expect(described_class).to have_received(:auto).once
    end

    it 'calls ::auto when passed auto as strategy' do
      allow(described_class).to receive(:auto).and_return([])
      described_class.archive('http://example.com', strategy: :auto)
      expect(described_class).to have_received(:auto).once
    end

    it 'calls ::crawl when passed crawl as strategy' do
      allow(described_class).to receive(:crawl).and_return([])
      described_class.archive('http://example.com', strategy: :crawl)
      expect(described_class).to have_received(:crawl).once
    end

    it 'calls ::urls when passed urls as strategy' do
      allow(described_class).to receive(:urls).and_return([])
      described_class.archive('http://example.com', strategy: :urls)
      expect(described_class).to have_received(:urls).once
    end

    it 'calls ::urls when passed url as strategy' do
      allow(described_class).to receive(:urls).and_return([])
      described_class.archive('http://example.com', strategy: :url)
      expect(described_class).to have_received(:urls).once
    end

    it 'calls ::sitemap when passed sitemap as strategy' do
      allow(described_class).to receive(:sitemap).and_return([])
      described_class.archive('http://example.com', strategy: :sitemap)
      expect(described_class).to have_received(:sitemap).once
    end

    context 'legacy strategy param' do
      it 'raises ArgumentError when passed unknown strategy' do
        expect do
          described_class.archive('http://example.com', :watman_strategy)
        end.to raise_error(ArgumentError)
      end

      it 'calls ::auto when passed auto as strategy' do
        allow(described_class).to receive(:auto).and_return([])
        described_class.archive('http://example.com', :auto)
        expect(described_class).to have_received(:auto).once
      end

      it 'calls ::crawl when passed crawl as strategy' do
        allow(described_class).to receive(:crawl).and_return([])
        described_class.archive('http://example.com', :crawl)
        expect(described_class).to have_received(:crawl).once
      end

      it 'calls ::urls when passed urls as strategy' do
        allow(described_class).to receive(:urls).and_return([])
        described_class.archive('http://example.com', :urls)
        expect(described_class).to have_received(:urls).once
      end

      it 'calls ::urls when passed url as strategy' do
        allow(described_class).to receive(:urls).and_return([])
        described_class.archive('http://example.com', :url)
        expect(described_class).to have_received(:urls).once
      end

      it 'calls ::sitemap when passed sitemap as strategy' do
        allow(described_class).to receive(:sitemap).and_return([])
        described_class.archive('http://example.com', :sitemap)
        expect(described_class).to have_received(:sitemap).once
      end
    end
  end

  describe '::auto' do
    it 'calls Sitemapper::autodiscover and ::crawl if Sitemapper returned empty result' do
      allow(described_class::Sitemapper).to receive(:autodiscover).and_return([])
      allow(described_class).to receive(:crawl).and_return([])

      described_class.auto('http://example.com')

      expect(described_class::Sitemapper).to have_received(:autodiscover).once
      expect(described_class).to have_received(:crawl).once
    end

    it 'calls Sitemapper::autodiscover and ::urls if Sitemapper returned non-empty result' do
      allow(described_class::Sitemapper).to receive(:autodiscover).and_return(['url'])
      allow(described_class).to receive(:urls).and_return([])

      described_class.auto('http://example.com')

      expect(described_class::Sitemapper).to have_received(:autodiscover).once
      expect(described_class).to have_received(:urls).once
    end
  end

  describe '::crawl' do
    it 'calls Archive::crawl' do
      allow(described_class::Archive).to receive(:crawl).and_return([])

      described_class.crawl('http://example.com')

      expect(described_class::Archive).to have_received(:crawl).once
    end
  end

  describe '::urls' do
    it 'calls Archive::post' do
      allow(described_class::Archive).to receive(:post).and_return([])

      described_class.urls('http://example.com')

      expect(described_class::Archive).to have_received(:post).once
    end
  end

  describe '::sitemap' do
    it 'calls URLCollector::sitemap and Archive::post' do
      allow(described_class::URLCollector).to receive(:sitemap).and_return([])
      allow(described_class::Archive).to receive(:post).and_return([])

      described_class.sitemap('http://example.com')

      expect(described_class::URLCollector).to have_received(:sitemap).once
      expect(described_class::Archive).to have_received(:post).once
    end
  end

  describe '::default_logger!' do
    it 'has NullLogger as the default logger' do
      described_class.default_logger!
      expect(described_class.logger.class).to eq(described_class::NullLogger)
    end
  end

  describe '::logger=' do
    it 'can set logger' do
      MyLogger = Struct.new(:name).new('buren')
      described_class.logger = MyLogger
      expect(described_class.logger).to eq(MyLogger)
    end
  end

  describe '::user_agent=' do
    it 'can set user_agent' do
      described_class.user_agent = 'buren'
      expect(described_class.user_agent).to eq('buren')
    end
  end

  describe '::concurrency=' do
    it 'can set concurrency' do
      described_class.concurrency = 1
      expect(described_class.concurrency).to eq(1)
    end
  end

  describe '::max_limit=' do
    it 'can set max_limit' do
      described_class.max_limit = 1
      expect(described_class.max_limit).to eq(1)
    end
  end
end
