# frozen_string_literal: true

require "json"

module Crawlscope
  class Sitemap
    Manifest = Data.define(:root_sitemap, :base_url, :entries, :documents, :errors) do
      def initialize(root_sitemap:, base_url:, entries: [], documents: [], errors: [])
        super
      end

      def urls
        entries.map(&:url)
      end

      def to_h
        {
          root_sitemap: root_sitemap,
          base_url: base_url,
          entries: entries.map(&:to_h),
          documents: documents.map(&:to_h),
          errors: errors
        }
      end

      def to_json(*_arguments)
        JSON.pretty_generate(to_h)
      end
    end
  end
end
