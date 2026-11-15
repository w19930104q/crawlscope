# frozen_string_literal: true

require "fileutils"

module Crawlscope
  class SitemapManifestWriter
    def initialize(path:)
      @path = path
    end

    def write(manifest)
      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, manifest.to_json)
      @path
    end
  end
end
