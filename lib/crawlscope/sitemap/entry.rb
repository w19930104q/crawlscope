# frozen_string_literal: true

module Crawlscope
  class Sitemap
    Entry = Data.define(:loc, :url, :lastmod, :alternates, :sitemap, :parent_sitemaps) do
      def initialize(loc:, url:, lastmod: nil, alternates: [], sitemap:, parent_sitemaps: [])
        super
      end

      def to_h
        {
          loc: loc,
          url: url,
          lastmod: lastmod,
          alternates: alternates.map(&:to_h),
          sitemap: sitemap,
          parent_sitemaps: parent_sitemaps
        }
      end
    end
  end
end
