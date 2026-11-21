# frozen_string_literal: true

require "jekyll"
require_relative "../static_resourcesync"

module StaticResourceSync
  module Jekyll
    def self.config(site)
      raw = site.config["static_resourcesync"]
      return { "enabled" => false } if raw == false
      return raw if raw.is_a?(Hash)

      # Also accept boolean `resourcesync: true/false` for convenience
      if site.config.key?("resourcesync")
        return { "enabled" => site.config["resourcesync"] == true }
      end

      {}
    end

    def self.enabled?(site)
      cfg = config(site)
      cfg["enabled"] != false
    end

    def self.capabilitylist_href(site)
      cfg = config(site)
      if cfg["link_href"] && !cfg["link_href"].to_s.strip.empty?
        href = cfg["link_href"].to_s.strip
        return href if href.match?(%r{\Ahttps?://}i)

        return "#{site.config['url'].to_s.chomp('/')}#{href.start_with?('/') ? href : "/#{href}"}"
      end

      return nil unless enabled?(site)

      dir = (cfg["dir"] || StaticResourceSync::DEFAULT_DIR).to_s.sub(%r{\A/+}, "").sub(%r{/+\z}, "")
      base = "#{site.config['url'].to_s.chomp('/')}#{site.config['baseurl'].to_s.chomp('/')}"
      "#{base}/#{dir}/capabilitylist.xml"
    end

    def self.inject_link(item)
      site = item.site
      cfg = config(site)
      return if cfg["inject_link"] == false
      return unless item.output_ext == ".html"
      return unless item.output.is_a?(String)
      return if item.output.include?('rel="resourcesync"') || item.output.include?("rel='resourcesync'")

      href = capabilitylist_href(site)
      return if href.nil? || href.empty?

      tag = %(<link rel="resourcesync" href="#{StaticResourceSync.esc(href)}">\n</head>)
      item.output = item.output.sub(%r{</head>}i, tag)
    end

    def self.run(site)
      return unless enabled?(site)

      cfg = config(site)
      builder = StaticResourceSync::Builder.new(
        dest: site.dest,
        url: site.config["url"].to_s,
        baseurl: site.config["baseurl"].to_s,
        dir: cfg["dir"] || StaticResourceSync::DEFAULT_DIR,
        well_known: cfg.key?("well_known") ? cfg["well_known"] : nil,
        days: cfg["days"] || StaticResourceSync::DEFAULT_DAYS,
        include_globs: cfg["include"] || StaticResourceSync::DEFAULT_INCLUDE,
        exclude_globs: cfg["exclude"] || StaticResourceSync::DEFAULT_EXCLUDE,
        described_by: cfg.key?("described_by") ? cfg["described_by"] : "data.html",
        previous: cfg.key?("previous") ? cfg["previous"] : "live",
        logger: ::Jekyll.logger
      )
      builder.build
    end
  end
end

Jekyll::Hooks.register([:pages, :documents], :post_render) do |item|
  StaticResourceSync::Jekyll.inject_link(item)
end

Jekyll::Hooks.register(:site, :post_write) do |site|
  StaticResourceSync::Jekyll.run(site)
end
