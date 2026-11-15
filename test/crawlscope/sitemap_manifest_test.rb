# frozen_string_literal: true

require "test_helper"

class CrawlscopeSitemapManifestTest < Minitest::Test
  FIXTURE_ROOT = File.expand_path("../fixtures/sitemap", __dir__)

  def test_manifest_records_parent_chain_raw_and_normalized_url_lastmod_and_alternates
    manifest = parser.manifest(base_url: "https://example.com")

    assert_equal fixture_path("sitemap.xml"), manifest.root_sitemap
    assert_equal "https://example.com", manifest.base_url

    entry = manifest.entries.first
    assert_equal "/products/red-shoe?utm_source=feed", entry.loc
    assert_equal "https://example.com/products/red-shoe?utm_source=feed", entry.url
    assert_equal "2026-11-01T12:00:00Z", entry.lastmod
    assert_equal fixture_path("pages.xml"), entry.sitemap
    assert_equal [fixture_path("sitemap.xml")], entry.parent_sitemaps

    assert_equal(
      [
        {
          hreflang: "en",
          href: "https://example.com/products/red-shoe?utm_source=feed",
          normalized_href: "https://example.com/products/red-shoe?utm_source=feed"
        },
        {
          hreflang: "fr",
          href: "https://example.com/fr/products/red-shoe",
          normalized_href: "https://example.com/fr/products/red-shoe"
        },
        {
          hreflang: "x-default",
          href: "https://example.com/products/red-shoe",
          normalized_href: "https://example.com/products/red-shoe"
        }
      ],
      entry.alternates.map(&:to_h)
    )
  end

  def test_manifest_keeps_url_order_and_deduplicates_repeated_entries
    manifest = parser.manifest(base_url: "https://example.com")

    assert_equal(
      [
        "https://example.com/products/red-shoe?utm_source=feed",
        "https://example.com/about",
        "https://example.com/gzipped/guide"
      ],
      manifest.urls
    )

    assert_equal 3, manifest.entries.size
    assert_equal 1, manifest.entries.count { |entry| entry.url == "https://example.com/products/red-shoe?utm_source=feed" }
  end

  def test_manifest_visits_each_sitemap_only_once_including_self_references
    manifest = parser.manifest(base_url: "https://example.com")

    sources = manifest.documents.map(&:source)
    assert_equal sources, sources.uniq
    assert_includes sources, fixture_path("sitemap.xml")
    assert_equal 1, sources.count { |source| source == fixture_path("sitemap.xml") }
  end

  def test_manifest_records_broken_child_sitemap_as_a_located_error
    manifest = parser.manifest(base_url: "https://example.com")

    assert_equal 1, manifest.errors.size
    error = manifest.errors.first
    assert_equal fixture_path("broken.xml"), error.fetch(:source)
    assert_includes error.fetch(:message), "unexpected root"
    assert_equal [fixture_path("sitemap.xml")], error.fetch(:parent_sitemaps)

    broken_document = manifest.documents.find { |document| document.source == fixture_path("broken.xml") }
    assert_nil broken_document.root
    assert_equal error.fetch(:message), broken_document.error
  end

  def test_manifest_tolerates_broken_children_and_keeps_remaining_entries
    manifest = parser.manifest(base_url: "https://example.com")

    assert_equal 3, manifest.entries.size
    assert_includes manifest.urls, "https://example.com/gzipped/guide"
  end

  def test_manifest_reads_gzipped_child_sitemaps
    manifest = parser.manifest(base_url: "https://example.com")

    gzipped_entry = manifest.entries.find { |entry| entry.sitemap == fixture_path("posts.xml.gz") }
    refute_nil gzipped_entry
    assert_equal "https://example.com/gzipped/guide", gzipped_entry.url
    assert_equal "2026-08-15T09:30:00Z", gzipped_entry.lastmod
    assert_equal %w[en es], gzipped_entry.alternates.map(&:hreflang)
  end

  def test_manifest_documents_track_their_parent_chain
    manifest = parser.manifest(base_url: "https://example.com")

    pages_document = manifest.documents.find { |document| document.source == fixture_path("pages.xml") }
    assert_equal "urlset", pages_document.root
    assert_equal [fixture_path("sitemap.xml")], pages_document.parent_sitemaps

    root_document = manifest.documents.find { |document| document.source == fixture_path("sitemap.xml") }
    assert_equal "sitemapindex", root_document.root
    assert_empty root_document.parent_sitemaps
    assert_nil root_document.error
  end

  def test_manifest_serializes_to_json
    manifest = parser.manifest(base_url: "https://example.com")
    decoded = JSON.parse(manifest.to_json)

    assert_equal fixture_path("sitemap.xml"), decoded.fetch("root_sitemap")
    assert_equal %w[root_sitemap base_url entries documents errors].sort, decoded.keys.sort
    assert_equal(
      %w[loc url lastmod alternates sitemap parent_sitemaps].sort,
      decoded.fetch("entries").first.keys.sort
    )
    assert_equal(
      %w[source root parent_sitemaps error].sort,
      decoded.fetch("documents").first.keys.sort
    )
  end

  def test_urls_remains_strict_and_raises_for_broken_child_sitemaps
    error = assert_raises(Crawlscope::ValidationError) do
      parser.urls(base_url: "https://example.com")
    end

    assert_includes error.message, fixture_path("broken.xml")
  end

  def test_urls_returns_the_same_ordered_unique_urls_as_the_manifest
    healthy = Crawlscope::Sitemap.new(
      path: fixture_path("pages.xml"),
      fetch_executor: :threaded
    )

    manifest = healthy.manifest(base_url: "https://example.com")
    assert_equal manifest.urls, healthy.urls(base_url: "https://example.com")
  end

  def test_manifest_missing_lastmod_and_alternates_default_to_nil_and_empty
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "minimal.xml"), <<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>/minimal</loc></url>
        </urlset>
      XML

      manifest = Crawlscope::Sitemap.new(path: File.join(dir, "minimal.xml")).manifest(base_url: "https://example.com")
      entry = manifest.entries.first

      assert_nil entry.lastmod
      assert_empty entry.alternates
      assert_empty entry.parent_sitemaps
      assert_empty manifest.errors
    end
  end

  def test_remote_manifest_preserves_full_parent_chain_and_recovers_from_broken_children
    stub_request(:get, "https://www.example.com/sitemap.xml")
      .to_return(
        status: 200,
        body: <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
            <sitemap><loc>/sitemaps/content.xml</loc></sitemap>
            <sitemap><loc>/sitemaps/missing.xml</loc></sitemap>
          </sitemapindex>
        XML
      )

    stub_request(:get, "https://www.example.com/sitemaps/content.xml")
      .to_return(
        status: 200,
        body: <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">
            <url>
              <loc>https://www.example.com/features/reviews</loc>
              <lastmod>2026-11-01</lastmod>
              <xhtml:link rel="alternate" hreflang="en" href="https://www.example.com/features/reviews"/>
            </url>
          </urlset>
        XML
      )

    stub_request(:get, "https://www.example.com/sitemaps/missing.xml")
      .to_return(status: 500, body: "error")

    manifest = Crawlscope::Sitemap.new(
      path: "https://www.example.com/sitemap.xml",
      fetch_executor: :threaded
    ).manifest(base_url: "https://www.example.com")

    assert_equal ["https://www.example.com/features/reviews"], manifest.urls
    entry = manifest.entries.first
    assert_equal "https://www.example.com/sitemaps/content.xml", entry.sitemap
    assert_equal ["https://www.example.com/sitemap.xml"], entry.parent_sitemaps
    assert_equal "2026-11-01", entry.lastmod
    assert_equal "en", entry.alternates.first.hreflang

    error = manifest.errors.first
    assert_equal "https://www.example.com/sitemaps/missing.xml", error.fetch(:source)
    assert_equal "Sitemap https://www.example.com/sitemaps/missing.xml returned HTTP 500", error.fetch(:message)
  end

  private

  def parser
    Crawlscope::Sitemap.new(path: fixture_path("sitemap.xml"), fetch_executor: :threaded)
  end

  def fixture_path(name)
    File.join(FIXTURE_ROOT, name)
  end
end
