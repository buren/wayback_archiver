require 'spec_helper'

describe WaybackArchiver::CrawlUrl do
  let(:crawl_url) { WaybackArchiver::CrawlUrl.new('example.com') }

  # it 'sets base hostname' do
  #   expect(crawl_url.base_hostname).to eq ('example')
  #   expect(crawl_url.resolved_base_url.com).to eq ('example')
  # end


  describe '#url_from_relative' do 
    it 'returns correct path from base relative url' do
      url  = crawl_url.send(:url_from_relative, '/', '')
      url1 = crawl_url.send(:url_from_relative, '/path/to/resource', '')
      url3 = crawl_url.send(:url_from_relative, '', '')
      url4 = crawl_url.send(:url_from_relative, 'path/to/resource', '')
      expect(url).to eq 'example.com/'
      expect(url1).to eq 'example.com/path/to/resource'
      expect(url3).to eq 'example.com/'
      expect(url4).to eq 'example.com/path/to/resource'
    end

    it 'returns correct path from current page relative url' do
      url = crawl_url.send(:url_from_relative, '../path/to/resource', 'example.com/some/path')
      expect(url).to eq 'example.com/'
    end
  end
end
