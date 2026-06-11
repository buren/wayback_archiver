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

    it 'passes hosts to ::auto' do
      hosts = [/example\.com/, /other\.example\.com/]
      allow(described_class).to receive(:auto).and_return([])
      described_class.archive('http://example.com', hosts: hosts)
      expect(described_class).to have_received(:auto).with(
        'http://example.com',
        hash_including(hosts: hosts)
      )
    end

    it 'passes hosts to ::crawl' do
      hosts = [/example\.com/]
      allow(described_class).to receive(:crawl).and_return([])
      described_class.archive('http://example.com', strategy: :crawl, hosts: hosts)
      expect(described_class).to have_received(:crawl).with(
        'http://example.com',
        hash_including(hosts: hosts)
      )
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

    it 'calls ::rss when passed rss as strategy' do
      allow(described_class).to receive(:rss).and_return([])
      described_class.archive('http://example.com/feed.xml', strategy: :rss)
      expect(described_class).to have_received(:rss).once
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

      it 'calls ::rss when passed rss as strategy' do
        allow(described_class).to receive(:rss).and_return([])
        described_class.archive('http://example.com/feed.xml', :rss)
        expect(described_class).to have_received(:rss).once
      end
    end
  end

  describe '::auto' do
    let(:source) { 'http://example.com' }

    it 'uses sitemap URLs when sitemap found' do
      allow(described_class::Sitemapper).to receive(:autodiscover).and_return(%w[url1 url2])
      allow(described_class::Archive).to receive(:post).and_return([])

      described_class.auto(source)

      expect(described_class::Sitemapper).to have_received(:autodiscover).once
      expect(described_class::Archive).to have_received(:post).once
    end

    it 'falls through to crawl when no sitemap found' do
      allow(described_class::Sitemapper).to receive(:autodiscover).and_return([])
      allow(described_class::Archive).to receive(:crawl).and_return([])

      described_class.auto(source)

      expect(described_class::Archive).to have_received(:crawl).once
    end

    it 'passes hosts to crawl when falling through' do
      hosts = [/careers\.example\.com/, /www\.example\.com/]
      allow(described_class::Sitemapper).to receive(:autodiscover).and_return([])
      allow(described_class::Archive).to receive(:crawl).and_return([])

      described_class.auto(source, hosts: hosts)

      expect(described_class::Archive).to have_received(:crawl).with(
        source,
        hash_including(hosts: hosts)
      )
    end

    it 'does not use feed detection' do
      allow(described_class::Sitemapper).to receive(:autodiscover).and_return([])
      allow(described_class::FeedParser).to receive(:autodiscover)
      allow(described_class::Archive).to receive(:crawl).and_return([])

      described_class.auto(source)

      expect(described_class::FeedParser).not_to have_received(:autodiscover)
    end

    it 'fires on_resolved with :sitemap when sitemap found' do
      allow(described_class::Sitemapper).to receive(:autodiscover).and_return(%w[url1 url2])
      allow(described_class::Archive).to receive(:post).and_return([])

      described_class.auto(source)

      expect(WaybackArchiver.listener.resolved_events.first[:strategy]).to eq(:sitemap)
      expect(WaybackArchiver.listener.resolved_events.first[:url_count]).to eq(2)
    end

    it 'fires on_resolved with :crawl when falling through to crawl' do
      allow(described_class::Sitemapper).to receive(:autodiscover).and_return([])
      allow(described_class::Archive).to receive(:crawl).and_return([])

      described_class.auto(source)

      expect(WaybackArchiver.listener.resolved_events.first[:strategy]).to eq(:crawl)
      expect(WaybackArchiver.listener.resolved_events.first[:url_count]).to be_nil
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

  describe '::rss' do
    it 'calls URLCollector::feed and Archive::post' do
      allow(described_class::URLCollector).to receive(:feed).and_return([])
      allow(described_class::Archive).to receive(:post).and_return([])

      described_class.rss('http://example.com/feed.xml')

      expect(described_class::URLCollector).to have_received(:feed).once
      expect(described_class::Archive).to have_received(:post).once
    end
  end

  describe 'default logger' do
    it 'has NullLogger as the default logger' do
      described_class.config.logger = nil
      expect(described_class.logger.class).to eq(described_class::NullLogger)
    end
  end

  describe 'config.logger=' do
    it 'can set logger' do
      MyLogger = Struct.new(:name).new('buren')
      described_class.config.logger = MyLogger
      expect(described_class.logger).to eq(MyLogger)
    end
  end

  describe '::user_agent=' do
    it 'can set user_agent' do
      described_class.config.user_agent = 'buren'
      expect(described_class.config.user_agent).to eq('buren')
    end
  end

  describe '::concurrency=' do
    it 'can set concurrency' do
      described_class.config.concurrency = 1
      expect(described_class.config.concurrency).to eq(1)
    end
  end

  describe '::max_limit=' do
    it 'can set max_limit' do
      described_class.config.max_limit = 1
      expect(described_class.config.max_limit).to eq(1)
    end
  end

  describe '::access_key' do
    it 'can set and get access_key' do
      described_class.config.access_key = 'my-access-key'
      expect(described_class.config.access_key).to eq('my-access-key')
    end

    it 'falls back to WAYBACK_ACCESS_KEY env var' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('WAYBACK_ACCESS_KEY').and_return('env-key')
      expect(described_class.config.access_key).to eq('env-key')
    end

    it 'falls back to IA_S3_ACCESS_KEY env var' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('WAYBACK_ACCESS_KEY').and_return(nil)
      allow(ENV).to receive(:[]).with('IA_S3_ACCESS_KEY').and_return('ia-key')
      expect(described_class.config.access_key).to eq('ia-key')
    end

    it 'prefers programmatic value over env var' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('WAYBACK_ACCESS_KEY').and_return('env-key')
      described_class.config.access_key = 'programmatic-key'
      expect(described_class.config.access_key).to eq('programmatic-key')
    end
  end

  describe '::secret_key' do
    it 'can set and get secret_key' do
      described_class.config.secret_key = 'my-secret-key'
      expect(described_class.config.secret_key).to eq('my-secret-key')
    end

    it 'falls back to WAYBACK_SECRET_KEY env var' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('WAYBACK_SECRET_KEY').and_return('env-secret')
      expect(described_class.config.secret_key).to eq('env-secret')
    end

    it 'falls back to IA_S3_SECRET_KEY env var' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('WAYBACK_SECRET_KEY').and_return(nil)
      allow(ENV).to receive(:[]).with('IA_S3_SECRET_KEY').and_return('ia-secret')
      expect(described_class.config.secret_key).to eq('ia-secret')
    end
  end

  describe '::credentials?' do
    it 'returns true when both keys are present' do
      described_class.config.access_key = 'key'
      described_class.config.secret_key = 'secret'
      expect(described_class.config.credentials?).to eq(true)
    end

    it 'returns false when access_key is missing' do
      described_class.config.secret_key = 'secret'
      expect(described_class.config.credentials?).to eq(false)
    end

    it 'returns false when secret_key is missing' do
      described_class.config.access_key = 'key'
      expect(described_class.config.credentials?).to eq(false)
    end

    it 'returns false when both keys are missing' do
      expect(described_class.config.credentials?).to eq(false)
    end
  end

  describe '::configure' do
    it 'yields self for block-style configuration' do
      described_class.configure do |config|
        config.concurrency = 8
        config.access_key = 'block-key'
        config.secret_key = 'block-secret'
      end

      expect(described_class.config.concurrency).to eq(8)
      expect(described_class.config.access_key).to eq('block-key')
      expect(described_class.config.secret_key).to eq('block-secret')
    end

    it 'returns the config' do
      result = described_class.configure { |c| }
      expect(result).to eq(described_class.config)
    end
  end


  describe '::check' do
    it 'delegates to CDX.check_urls' do
      urls = %w[http://a.com http://b.com]
      allow(described_class::CDX).to receive(:check_urls).and_return([])

      described_class.check(urls)

      expect(described_class::CDX).to have_received(:check_urls)
        .with(urls, concurrency: WaybackArchiver.config.concurrency, from: nil)
    end

    it 'passes from: through to CDX.check_urls' do
      urls = %w[http://a.com]
      allow(described_class::CDX).to receive(:check_urls).and_return([])

      described_class.check(urls, from: '20260604120000')

      expect(described_class::CDX).to have_received(:check_urls)
        .with(urls, concurrency: WaybackArchiver.config.concurrency, from: '20260604120000')
    end

    it 'passes block through to CDX.check_urls' do
      urls = %w[http://a.com]
      blk = proc { |r| r }
      allow(described_class::CDX).to receive(:check_urls)

      described_class.check(urls, &blk)

      expect(described_class::CDX).to have_received(:check_urls) do |_urls, **_opts, &block|
        expect(block).to eq(blk)
      end
    end
  end

  describe '::respect_robots_txt=' do
    it 'can set and get respect_robots_txt' do
      described_class.config.respect_robots_txt = false
      expect(described_class.config.respect_robots_txt).to eq(false)
    end
  end

  describe '::discover_urls' do
    it 'returns Array(source) for :urls strategy' do
      result = described_class.discover_urls(%w[http://a.com http://b.com], strategy: :urls)
      expect(result).to eq(%w[http://a.com http://b.com])
    end

    it 'wraps a single URL string in an array for :urls strategy' do
      result = described_class.discover_urls('http://a.com', strategy: :urls)
      expect(result).to eq(['http://a.com'])
    end

    it 'delegates to URLCollector.sitemap for :sitemap strategy' do
      allow(described_class::URLCollector).to receive(:sitemap).and_return(%w[http://a.com])

      result = described_class.discover_urls('http://example.com', strategy: :sitemap)

      expect(result).to eq(%w[http://a.com])
      expect(described_class::URLCollector).to have_received(:sitemap).with('http://example.com')
    end

    it 'delegates to URLCollector.feed for :rss strategy' do
      allow(described_class::URLCollector).to receive(:feed).and_return(%w[http://a.com])

      result = described_class.discover_urls('http://example.com/feed.xml', strategy: :rss)

      expect(result).to eq(%w[http://a.com])
      expect(described_class::URLCollector).to have_received(:feed).with('http://example.com/feed.xml')
    end

    it 'delegates to URLCollector.crawl for :crawl strategy' do
      hosts = ['example.com']
      allow(described_class::URLCollector).to receive(:crawl).and_return(%w[http://a.com])

      result = described_class.discover_urls('http://example.com', strategy: :crawl, hosts: hosts, limit: 10)

      expect(described_class::URLCollector).to have_received(:crawl)
        .with('http://example.com', hosts: hosts, limit: 10)
    end

    it 'uses auto discovery cascade for :auto strategy' do
      allow(described_class::Sitemapper).to receive(:autodiscover).and_return(%w[http://a.com http://b.com])

      result = described_class.discover_urls('http://example.com', strategy: :auto)

      expect(result).to eq(%w[http://a.com http://b.com])
    end

    it 'raises ArgumentError for unknown strategy' do
      expect do
        described_class.discover_urls('http://example.com', strategy: :bogus)
      end.to raise_error(ArgumentError, /Unknown strategy/)
    end

    context 'auto strategy' do
      let(:source) { 'http://example.com' }

      it 'returns sitemap URLs when sitemap found' do
        allow(described_class::Sitemapper).to receive(:autodiscover).and_return(%w[http://example.com/page1 http://example.com/page2])

        result = described_class.discover_urls(source, strategy: :auto)

        expect(result).to eq(%w[http://example.com/page1 http://example.com/page2])
      end

      it 'falls through to crawl when no sitemap found' do
        allow(described_class::Sitemapper).to receive(:autodiscover).and_return([])
        allow(described_class::URLCollector).to receive(:crawl).and_return(%w[http://example.com/page])

        result = described_class.discover_urls(source, strategy: :auto)

        expect(result).to eq(%w[http://example.com/page])
      end
    end
  end
end
