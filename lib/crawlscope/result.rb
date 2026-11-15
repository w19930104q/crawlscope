# frozen_string_literal: true

module Crawlscope
  Result = Data.define(:base_url, :sitemap_path, :urls, :pages, :issues, :sitemap_manifest) do
    def initialize(base_url:, sitemap_path:, urls:, pages:, issues:, sitemap_manifest: nil)
      super
    end

    def ok?
      issues.none?(&:error?)
    end

    def server_timing_summary
      ServerTiming::Summary.new(pages)
    end
  end
end
