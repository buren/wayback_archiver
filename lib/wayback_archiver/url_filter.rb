module WaybackArchiver
  class URLFilter
    def initialize(include_ext: nil, exclude_ext: nil)
      @include_ext = normalize(include_ext)
      @exclude_ext = normalize(exclude_ext)
      @noop = @include_ext.nil? && @exclude_ext.nil?
    end

    def match?(url)
      return true if @noop

      ext = url_extension(url)
      return false if @include_ext && !@include_ext.include?(ext)
      return false if @exclude_ext&.include?(ext)

      true
    end

    def apply(urls)
      return urls if @noop

      before = urls.length
      filtered = urls.select { |url| match?(url) }
      skipped = before - filtered.length
      WaybackArchiver.logger.info "Filtered #{skipped} URL(s) by extension" if skipped > 0
      filtered
    end

    private

    def normalize(exts)
      return nil if exts.nil?

      exts.map { |e| e.delete_prefix('.').downcase }.freeze
    end

    def url_extension(url)
      path = url.split('?', 2).first.split('#', 2).first
      File.extname(path).delete_prefix('.').downcase
    end
  end
end
