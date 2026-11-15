# frozen_string_literal: true

require "faraday"
require "faraday/follow_redirects"
require "nokogiri"
require "stringio"
require "uri"
require "zlib"

module Crawlscope
  class Sitemap
    SITEMAP_NAMESPACE = {"xmlns" => "http://www.sitemaps.org/schemas/sitemap/0.9"}.freeze
    GZIP_MAGIC_BYTES = "\x1F\x8B".b.freeze
    ROOT_ELEMENTS = %w[sitemapindex urlset].freeze

    def initialize(path:, adapter: nil, concurrency: Configuration::DEFAULT_CONCURRENCY, fetch_executor: Configuration::DEFAULT_FETCH_EXECUTOR, profile_token: nil, timeout_seconds: Configuration::DEFAULT_TIMEOUT_SECONDS)
      @path = path
      @adapter = adapter
      @concurrency = concurrency
      @fetch_executor = fetch_executor
      @profile_token = profile_token
      @timeout_seconds = timeout_seconds
    end

    def urls(base_url:)
      manifest = build_manifest(base_url: base_url, strict: true)
      raise ValidationError, manifest.errors.first.fetch(:message) unless manifest.errors.empty?

      manifest.urls
    end

    def manifest(base_url:)
      build_manifest(base_url: base_url, strict: false)
    end

    private

    def build_manifest(base_url:, strict:)
      state = TraversalState.new
      collect(@path, base_url: base_url, ancestors: [], state: state, strict: strict)

      Manifest.new(
        root_sitemap: @path,
        base_url: base_url.to_s,
        entries: state.entries,
        documents: state.documents,
        errors: state.errors
      )
    end

    def collect(source, base_url:, ancestors:, state:, strict:)
      return if state.visited?(source)

      state.mark_visited(source)
      document, xml = read_document(source, base_url: base_url, ancestors: ancestors)
      state.add_document(document)

      if document.error
        state.add_error(source: source, message: document.error, parent_sitemaps: ancestors)
        raise ValidationError, document.error if strict

        return
      end

      if document.root == "sitemapindex"
        expand_index(xml, source: source, ancestors: ancestors, base_url: base_url, state: state, strict: strict)
      else
        parse_entries(xml, source: source, ancestors: ancestors, base_url: base_url, state: state)
      end
    end

    def read_document(source, base_url:, ancestors:)
      body = decode(read(source, base_url: base_url))
      xml = Nokogiri::XML(body)
      root_name = xml.root&.name
      unless ROOT_ELEMENTS.include?(root_name)
        return [
          Document.new(source: source, parent_sitemaps: ancestors, error: "Sitemap #{source} has unexpected root #{root_name.inspect}"),
          xml
        ]
      end

      [Document.new(source: source, root: root_name, parent_sitemaps: ancestors), xml]
    rescue ValidationError, Faraday::Error, SocketError, SystemCallError, Timeout::Error, Zlib::Error => error
      [Document.new(source: source, parent_sitemaps: ancestors, error: error.message), nil]
    end

    def expand_index(xml, source:, ancestors:, base_url:, state:, strict:)
      child_sources = xml.xpath("//xmlns:sitemap/xmlns:loc", SITEMAP_NAMESPACE).map do |node|
        resolve_child_source(source, node.text.to_s.strip, base_url: base_url)
      end

      fetch_executor.call(child_sources) do |child_source|
        collect(child_source, base_url: base_url, ancestors: ancestors + [source], state: state, strict: strict)
      end
    end

    def parse_entries(xml, source:, ancestors:, base_url:, state:)
      xml.xpath("//xmlns:url", SITEMAP_NAMESPACE).each do |url_node|
        loc_node = url_node.at_xpath("xmlns:loc", SITEMAP_NAMESPACE)
        raw_loc = loc_node&.text&.to_s&.strip
        next if raw_loc.nil? || raw_loc.empty?

        normalized_url = Url.normalize_for_base(raw_loc, base_url: base_url)
        next if state.entry_seen?(normalized_url)

        state.add_entry(
          Entry.new(
            loc: raw_loc,
            url: normalized_url,
            lastmod: parse_lastmod(url_node),
            alternates: parse_alternates(url_node, base_url: base_url),
            sitemap: source,
            parent_sitemaps: ancestors
          )
        )
      end
    end

    def parse_lastmod(url_node)
      node = url_node.at_xpath("xmlns:lastmod", SITEMAP_NAMESPACE)
      value = node&.text&.to_s&.strip
      value.nil? || value.empty? ? nil : value
    end

    def parse_alternates(url_node, base_url:)
      url_node.xpath("*[local-name()='link' and @rel='alternate']").filter_map do |link_node|
        href = link_node["href"].to_s.strip
        hreflang = link_node["hreflang"].to_s.strip
        next if href.empty? || hreflang.empty?

        Alternate.new(
          hreflang: hreflang,
          href: href,
          normalized_href: Url.normalize_for_base(href, base_url: base_url)
        )
      end
    end

    def read(source, base_url:)
      if Url.remote?(source)
        response = connection.get(source) do |request|
          RequestHeaders.add_profile_token(
            request.headers,
            url: source,
            base_url: base_url,
            profile_token: @profile_token
          )
        end
        unless response.status.to_i.between?(200, 299)
          raise ValidationError, "Sitemap #{source} returned HTTP #{response.status}"
        end

        response.body.to_s
      else
        File.binread(source)
      end
    end

    def decode(body)
      return body unless gzipped?(body)

      Zlib::GzipReader.new(StringIO.new(body)).read
    end

    def gzipped?(body)
      body.to_s.byteslice(0, 2) == GZIP_MAGIC_BYTES
    end

    def resolve_child_source(parent_source, child_loc, base_url:)
      if Url.remote?(parent_source)
        Url.normalize_for_base(URI.join(parent_source, child_loc).to_s, base_url: base_url)
      elsif (local_child_path = local_child_path(parent_source, child_loc))
        local_child_path
      elsif Url.remote?(child_loc)
        child_loc
      else
        File.expand_path(child_loc, File.dirname(parent_source))
      end
    end

    def local_child_path(parent_source, child_loc)
      basename = File.basename(URI.parse(child_loc).path.to_s)
      return if basename.empty?

      path = File.expand_path(basename, File.dirname(parent_source))
      path if File.file?(path)
    rescue URI::InvalidURIError
      nil
    end

    def connection
      Faraday.new do |faraday|
        faraday.response(
          :follow_redirects,
          limit: Http::MAX_REDIRECTS,
          callback: RequestHeaders.method(:strip_profile_token_on_cross_origin_redirect)
        )
        faraday.options.timeout = @timeout_seconds
        faraday.options.open_timeout = @timeout_seconds
        faraday.adapter @adapter if @adapter
      end
    end

    def fetch_executor
      @fetch_executor_instance ||= FetchExecutor.build(name: @fetch_executor, concurrency: @concurrency)
    end

    class TraversalState
      attr_reader :entries, :documents, :errors

      def initialize
        @visited = Set.new
        @seen_urls = Set.new
        @entries = []
        @documents = []
        @errors = []
        @mutex = Mutex.new
      end

      def visited?(source)
        @mutex.synchronize { @visited.include?(source) }
      end

      def mark_visited(source)
        @mutex.synchronize { @visited.add(source) }
      end

      def entry_seen?(url)
        @mutex.synchronize { @seen_urls.include?(url) }
      end

      def add_entry(entry)
        @mutex.synchronize do
          return if @seen_urls.include?(entry.url)

          @seen_urls.add(entry.url)
          @entries << entry
        end
      end

      def add_document(document)
        @mutex.synchronize { @documents << document }
      end

      def add_error(source:, message:, parent_sitemaps:)
        @mutex.synchronize do
          @errors << {source: source, message: message, parent_sitemaps: parent_sitemaps}
        end
      end
    end
  end
end
