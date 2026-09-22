require 'json'
require 'uri'

# HTTP fixtures for the documented examples (examples/*.rb, examples/*.sh) and
# the README's CLI commands, so those can be executed rather than only
# syntax-checked.
#
# Every stub answers from the request itself instead of a scripted sequence:
# the documented commands submit with concurrency up to 8, so a stub that
# depended on arrival order would be flaky. Anything a documented command can
# reach must be stubbed here — WebMock fails the example otherwise, which is
# the point.
module DocFixtures
  WAYBACK = 'https://web.archive.org'.freeze
  CAPTURE_TIMESTAMP = '20260326120000'.freeze
  # The smallest thing Screenshot.download will accept as an image.
  PNG_BYTES = ("\x89PNG\r\n\x1a\n".b + ('fixture' * 8).b).freeze
  OUTLINK_JOB = 'spn2-outlink-1'.freeze

  # A small site reachable at example.com, www.example.com and blog.example.com,
  # over either scheme, with a sitemap, a feed and a few non-HTML files for the
  # extension-filter examples.
  def stub_documented_site!
    # Declared least-specific first: WebMock prefers the most recently
    # declared matching stub, so the catch-all page must go in before the
    # sitemap and feed, or they are served HTML.
    stub_request(:get, %r{\Ahttps?://(www\.|blog\.)?example\.com(/.*)?\z})
      .to_return do |request|
        { status: 200, body: page_html(request.uri.to_s), headers: { 'Content-Type' => 'text/html; charset=utf-8' } }
      end

    # Real content types: the crawler only yields archivable ones, so serving
    # these as octet-stream would quietly drop them before any filter ran.
    { 'pdf' => 'application/pdf', 'zip' => 'application/zip', 'png' => 'image/png' }.each do |ext, type|
      stub_request(:get, %r{\Ahttps?://(www\.|blog\.)?example\.com/[^/]*\.#{ext}\z})
        .to_return(status: 200, body: 'binary', headers: { 'Content-Type' => type })
    end

    stub_request(:get, %r{\Ahttps?://(www\.|blog\.)?example\.com/robots\.txt\z})
      .to_return(status: 200, body: '', headers: { 'Content-Type' => 'text/plain' })

    stub_request(:get, %r{\Ahttps?://(www\.|blog\.)?example\.com/sitemap\.xml\z})
      .to_return(status: 200, body: sitemap_xml, headers: { 'Content-Type' => 'application/xml' })

    stub_request(:get, %r{\Ahttps?://(www\.|blog\.)?example\.com/feed\.xml\z})
      .to_return(status: 200, body: feed_xml, headers: { 'Content-Type' => 'application/rss+xml' })
  end

  # SPN2: submit, batch poll, single-job poll, user and system status, plus the
  # screenshot replay URL. Jobs are remembered so a poll can answer with the
  # URL and options the capture was actually submitted with.
  def stub_spn2!
    jobs = {}
    lock = Mutex.new
    counter = 0

    stub_request(:post, "#{WAYBACK}/save").to_return do |request|
      params = URI.decode_www_form(request.body.to_s).to_h
      job_id = lock.synchronize do
        counter += 1
        jobs["spn2-job-#{counter}"] = params
        "spn2-job-#{counter}"
      end
      { status: 200, body: { 'url' => params['url'], 'job_id' => job_id }.to_json }
    end

    stub_request(:post, "#{WAYBACK}/save/status").to_return do |request|
      ids = URI.decode_www_form(request.body.to_s).to_h['job_ids'].to_s.split(',')
      statuses = ids.to_h { |id| [id, capture_status(id, lock.synchronize { jobs[id] })] }
      { status: 200, body: statuses.to_json }
    end

    # Single-job status: the outlink poll in examples/track_outlinks.rb. Must
    # not shadow /save/status/user or /save/status/system.
    stub_request(:get, %r{#{Regexp.escape(WAYBACK)}/save/status/spn2-})
      .to_return do |request|
        job_id = request.uri.path.split('/').last
        { status: 200, body: capture_status(job_id, lock.synchronize { jobs[job_id] }).to_json }
      end

    stub_request(:get, %r{#{Regexp.escape(WAYBACK)}/save/status/system})
      .to_return(status: 200, body: { 'status' => 'ok' }.to_json)

    stub_request(:get, %r{#{Regexp.escape(WAYBACK)}/save/status/user})
      .to_return(
        status: 200,
        body: {
          'available' => 12, 'processing' => 0,
          'daily_captures' => 10, 'daily_captures_limit' => 100_000
        }.to_json
      )

    stub_request(:get, %r{#{Regexp.escape(WAYBACK)}/web/\d+/})
      .to_return(status: 200, body: PNG_BYTES, headers: { 'Content-Type' => 'image/png' })
  end

  # CDX, for --check and --skip-archived.
  def stub_cdx!
    stub_request(:get, %r{#{Regexp.escape(WAYBACK)}/cdx/search/cdx}).to_return do |request|
      url = URI.decode_www_form(request.uri.query.to_s).to_h['url'].to_s
      body = [
        %w[urlkey timestamp original mimetype statuscode digest length],
        ['com,example)/', CAPTURE_TIMESTAMP, "http://#{url}", 'text/html', '200', 'ABC123', '1234']
      ].to_json
      { status: 200, body: body }
    end
  end

  def stub_documented_endpoints!
    stub_documented_site!
    stub_spn2!
    stub_cdx!
  end

  private

  def capture_status(job_id, params)
    params ||= {}
    url = params['url'] || 'https://example.com'
    status = {
      'status' => 'success',
      'job_id' => job_id,
      'timestamp' => CAPTURE_TIMESTAMP,
      'original_url' => url,
      'duration_sec' => 1.5,
      'resources' => ["#{url}/style.css"],
      'outlinks' => {}
    }
    status['screenshot'] = "#{url}/screenshot.png" if params['capture_screenshot']
    status['outlinks'] = { 'https://example.com/about' => OUTLINK_JOB } if params['capture_outlinks']
    status
  end

  def page_html(url)
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head><title>#{url}</title></head>
        <body>
          <a href="https://example.com/about">About</a>
          <a href="https://example.com/contact">Contact</a>
          <a href="https://example.com/guide.pdf">Guide</a>
          <a href="https://example.com/bundle.zip">Bundle</a>
          <a href="https://example.com/logo.png">Logo</a>
          <a href="https://example.com/tag/ruby">Tagged</a>
          <a href="https://blog.example.com/post-1">Blog</a>
        </body>
      </html>
    HTML
  end

  def sitemap_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <url><loc>https://example.com/</loc></url>
        <url><loc>https://example.com/about</loc></url>
      </urlset>
    XML
  end

  def feed_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0">
        <channel>
          <title>Example</title>
          <link>https://example.com</link>
          <description>Example feed</description>
          <item><title>Post 1</title><link>https://example.com/post-1</link></item>
          <item><title>Post 2</title><link>https://example.com/post-2</link></item>
        </channel>
      </rss>
    XML
  end
end
