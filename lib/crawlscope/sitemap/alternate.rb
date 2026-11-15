# frozen_string_literal: true

module Crawlscope
  class Sitemap
    Alternate = Data.define(:hreflang, :href, :normalized_href) do
      def to_h
        {
          hreflang: hreflang,
          href: href,
          normalized_href: normalized_href
        }
      end
    end
  end
end
