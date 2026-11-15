# frozen_string_literal: true

require "test_helper"

class CrawlscopeRunTest < Minitest::Test
  FakeResult = Data.define(:reported, :sitemap_manifest) do
    def ok?
      true
    end

    def initialize(reported: true, sitemap_manifest: nil)
      super
    end
  end

  class FakeReporter
    attr_reader :result

    def report(result)
      @result = result
    end
  end

  class FakeAudit
    def initialize(result:)
      @result = result
    end

    def call
      @result
    end
  end

  class FakeConfiguration
    attr_reader :base_url, :received_arguments, :sitemap_path, :sitemap_manifest_path

    def initialize(result:, base_url: "https://example.com", sitemap_path: "/tmp/sitemap.xml", sitemap_manifest_path: nil)
      @result = result
      @base_url = base_url
      @sitemap_path = sitemap_path
      @sitemap_manifest_path = sitemap_manifest_path
    end

    def audit(base_url:, sitemap_path:, rule_names:, sitemap_manifest_path: nil)
      @received_arguments = {
        base_url: base_url,
        sitemap_path: sitemap_path,
        rule_names: rule_names,
        sitemap_manifest_path: sitemap_manifest_path
      }

      FakeAudit.new(result: @result)
    end
  end

  class JsonLdConfiguration
    attr_reader :output

    def initialize(output:, page:)
      @output = output
      @page = page
      @closed = false
    end

    def browser_factory
      -> { self }
    end

    def close
      @closed = true
    end

    def closed?
      @closed
    end

    def fetch(_url)
      @page
    end

    def network_idle_timeout_seconds
      5
    end

    def renderer
      :browser
    end

    def schema_registry
      Crawlscope::SchemaRegistry.default
    end

    def scroll_page?
      false
    end

    def timeout_seconds
      20
    end
  end

  def test_validate_passes_rule_names_to_configuration_audit
    result = FakeResult.new(reported: true)
    configuration = FakeConfiguration.new(result: result)
    reporter = FakeReporter.new

    run = Crawlscope::Run.new(configuration: configuration, reporter: reporter)
    returned_result = run.validate(rule_names: "links")

    assert_equal(
      {
        base_url: "https://example.com",
        sitemap_path: "/tmp/sitemap.xml",
        rule_names: "links",
        sitemap_manifest_path: nil
      },
      configuration.received_arguments
    )
    assert_same result, reporter.result
    assert_same result, returned_result
  end

  def test_validate_defaults_to_base_url_sitemap_when_not_configured
    result = FakeResult.new(reported: true)
    configuration = FakeConfiguration.new(result: result, base_url: "https://example.com", sitemap_path: nil)
    reporter = FakeReporter.new

    Crawlscope::Run.new(configuration: configuration, reporter: reporter).validate

    assert_equal(
      {
        base_url: "https://example.com",
        sitemap_path: "https://example.com/sitemap.xml",
        rule_names: nil,
        sitemap_manifest_path: nil
      },
      configuration.received_arguments
    )
  end

  def test_validate_uses_http_sitemap_for_localhost
    result = FakeResult.new(reported: true)
    configuration = FakeConfiguration.new(result: result, base_url: "http://localhost:3000", sitemap_path: nil)
    reporter = FakeReporter.new

    Crawlscope::Run.new(configuration: configuration, reporter: reporter).validate

    assert_equal(
      {
        base_url: "http://localhost:3000",
        sitemap_path: "http://localhost:3000/sitemap.xml",
        rule_names: nil,
        sitemap_manifest_path: nil
      },
      configuration.received_arguments
    )
  end

  def test_validate_passes_sitemap_manifest_path_to_configuration
    result = FakeResult.new
    configuration = FakeConfiguration.new(result: result, sitemap_manifest_path: "/tmp/manifest.json")
    reporter = FakeReporter.new

    Crawlscope::Run.new(configuration: configuration, reporter: reporter).validate(sitemap_manifest_path: "/tmp/manifest.json")

    assert_equal "/tmp/manifest.json", configuration.received_arguments.fetch(:sitemap_manifest_path)
  end

  def test_validate_writes_sitemap_manifest_when_path_is_configured
    Dir.mktmpdir do |dir|
      sitemap_path = File.join(dir, "sitemap.xml")
      File.write(sitemap_path, <<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>https://example.com/pricing</loc><lastmod>2026-11-01</lastmod></url>
        </urlset>
      XML
      manifest = Crawlscope::Sitemap.new(path: sitemap_path).manifest(base_url: "https://example.com")
      result = FakeResult.new(sitemap_manifest: manifest)
      manifest_path = File.join(dir, "nested", "sitemap-manifest.json")
      configuration = FakeConfiguration.new(result: result)

      Crawlscope::Run.new(configuration: configuration, reporter: FakeReporter.new)
        .validate(sitemap_manifest_path: manifest_path)

      assert File.exist?(manifest_path)
      decoded = JSON.parse(File.read(manifest_path))
      assert_equal sitemap_path, decoded.fetch("root_sitemap")
      assert_equal ["https://example.com/pricing"], decoded.fetch("entries").map { |entry| entry.fetch("url") }
      assert_equal "2026-11-01", decoded.fetch("entries").first.fetch("lastmod")
    end
  end

  def test_validate_without_manifest_path_skips_manifest_writing
    result = FakeResult.new(sitemap_manifest: nil)
    configuration = FakeConfiguration.new(result: result)

    Crawlscope::Run.new(configuration: configuration, reporter: FakeReporter.new).validate

    assert_nil configuration.received_arguments.fetch(:sitemap_manifest_path)
  end

  def test_validate_json_ld_reports_valid_structured_data
    body = <<~HTML
      <html>
        <head>
          <script type="application/ld+json">
            {"@type":"WebSite","name":"Example","url":"https://example.com"}
          </script>
        </head>
      </html>
    HTML
    page = Crawlscope::Page.new(
      url: "https://example.com",
      normalized_url: "https://example.com",
      final_url: "https://example.com",
      normalized_final_url: "https://example.com",
      status: 200,
      headers: {"content-type" => "text/html"},
      body: body,
      doc: nil
    )
    output = StringIO.new
    configuration = JsonLdConfiguration.new(output: output, page: page)
    report_dir = Dir.mktmpdir
    report_path = File.join(report_dir, "structured-data.json")

    result = Crawlscope::Run.new(configuration: configuration).validate_json_ld(
      urls: [page.url],
      debug: true,
      report_path: report_path,
      summary: true
    )

    assert result.ok?
    assert_predicate configuration, :closed?
    assert File.exist?(report_path)
    assert_equal ["https://example.com"], JSON.parse(File.read(report_path)).fetch("results").keys
    assert_includes output.string, "JavaScript mode enabled (Ferrum)"
    assert_includes output.string, "Validating JSON-LD on 1 URL(s)"
    assert_includes output.string, "Validation: OK"
    assert_includes output.string, "All 1 URLs passed validation."
  ensure
    FileUtils.rm_rf(report_dir) if report_dir
  end
end
