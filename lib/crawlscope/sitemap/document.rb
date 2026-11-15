# frozen_string_literal: true

module Crawlscope
  class Sitemap
    Document = Data.define(:source, :root, :parent_sitemaps, :error) do
      def initialize(source:, root: nil, parent_sitemaps: [], error: nil)
        super
      end

      def to_h
        {
          source: source,
          root: root,
          parent_sitemaps: parent_sitemaps,
          error: error
        }
      end
    end
  end
end
