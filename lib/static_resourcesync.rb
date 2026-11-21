# frozen_string_literal: true

require "cgi"
require "digest"
require "fileutils"
require "net/http"
require "rexml/document"
require "time"
require "uri"
require_relative "static_resourcesync/version"

module StaticResourceSync
  NS = 'xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:rs="http://www.openarchives.org/rs/terms/"'
  MAX_URLS = 50_000
  DEFAULT_DIR = "resourcesync"
  DEFAULT_DAYS = 90
  DEFAULT_INCLUDE = [
    "items/*.html",
    "iiif/**/*manifest*.json",
    "iiif/collection/**/*.json",
    "assets/data/*",
    "objects/**/*.{jpg,jpeg,png,webp,JPG,JPEG,PNG,WEBP}",
    "files/original/**/*.{jpg,jpeg,png,webp,JPG,JPEG,PNG,WEBP}"
  ].freeze
  DEFAULT_EXCLUDE = [
    "objects/iiif/**/*"
  ].freeze
  TYPES = {
    ".html" => "text/html",
    ".json" => "application/json",
    ".csv" => "text/csv",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".png" => "image/png",
    ".webp" => "image/webp",
    ".xml" => "application/xml"
  }.freeze

  def self.w3c(time)
    time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
  end

  def self.esc(str)
    CGI.escapeHTML(str.to_s)
  end

  def self.encode_path(path)
    path.split("/").map { |s| URI.encode_www_form_component(s).gsub("+", "%20") }.join("/")
  end

  def self.decode_rel_path(loc, baseurl)
    uri = URI.parse(loc.to_s.strip)
    path = uri.path.to_s
    prefix = baseurl.to_s.chomp("/")
    path = path.delete_prefix(prefix) if !prefix.empty? && path.start_with?("#{prefix}/")
    path = path.delete_prefix("/")
    path.split("/").map { |s| URI.decode_www_form_component(s) }.join("/")
  rescue URI::InvalidURIError
    nil
  end

  def self.mime_type(rel)
    return "application/ld+json" if rel.end_with?("manifest.json")

    TYPES[File.extname(rel).downcase] || "application/octet-stream"
  end

  def self.fetch_url(url, limit: 3, open_timeout: 5, read_timeout: 10)
    return nil if limit <= 0

    uri = URI.parse(url)
    return nil unless %w[http https].include?(uri.scheme)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = open_timeout
    http.read_timeout = read_timeout
    req = Net::HTTP::Get.new(uri.request_uri)
    req["User-Agent"] = "static_resourcesync/#{VERSION}"
    res = http.request(req)
    case res
    when Net::HTTPSuccess
      res.body
    when Net::HTTPRedirection
      location = res["location"]
      return nil unless location

      next_url = URI.join(uri, location).to_s
      fetch_url(next_url, limit: limit - 1, open_timeout: open_timeout, read_timeout: read_timeout)
    end
  rescue StandardError
    nil
  end

  def self.parse_resourcelist(xml_str, baseurl: "")
    return nil if xml_str.nil? || xml_str.strip.empty?

    doc = REXML::Document.new(xml_str)
    resources = {}
    doc.elements.each("urlset/url") do |el|
      loc = el.elements["loc"]&.text&.strip
      next unless loc

      rel = decode_rel_path(loc, baseurl)
      next if rel.nil? || rel.empty?

      lastmod = el.elements["lastmod"]&.text&.strip
      md = el.elements["rs:md"]
      hash_attr = md&.attributes&.[]("hash").to_s
      md5 = hash_attr.start_with?("md5:") ? hash_attr.delete_prefix("md5:") : nil
      length = md&.attributes&.[]("length")&.to_i
      resources[rel] = { "md5" => md5, "length" => length, "lastmod" => lastmod }
    end
    resources
  rescue REXML::ParseException
    nil
  end

  def self.parse_changelist(xml_str, baseurl: "")
    return { "from" => nil, "changes" => [] } if xml_str.nil? || xml_str.strip.empty?

    doc = REXML::Document.new(xml_str)
    root_md = doc.elements["urlset/rs:md"]
    from = root_md&.attributes&.[]("from")
    changes = []
    doc.elements.each("urlset/url") do |el|
      loc = el.elements["loc"]&.text&.strip
      next unless loc

      rel = decode_rel_path(loc, baseurl)
      next if rel.nil? || rel.empty?

      md = el.elements["rs:md"]
      change = md&.attributes&.[]("change")
      datetime = md&.attributes&.[]("datetime") || el.elements["lastmod"]&.text&.strip
      next unless change && datetime

      changes << { "path" => rel, "change" => change, "datetime" => datetime }
    end
    { "from" => from, "changes" => changes }
  rescue REXML::ParseException
    { "from" => nil, "changes" => [] }
  end

  class Builder
    attr_reader :dest, :url, :baseurl, :dir, :well_known, :days, :include_globs, :exclude_globs,
                :described_by, :previous, :logger

    def initialize(dest:, url:, baseurl: "", dir: DEFAULT_DIR, well_known: nil, days: DEFAULT_DAYS,
                   include_globs: DEFAULT_INCLUDE, exclude_globs: DEFAULT_EXCLUDE,
                   described_by: "data.html", previous: "live", logger: nil)
      @dest = dest.to_s
      @url = url.to_s.chomp("/")
      @baseurl = baseurl.to_s.chomp("/")
      @dir = dir.to_s.sub(%r{\A/+}, "").sub(%r{/+\z}, "")
      @well_known = well_known.nil? ? @baseurl.empty? : !!well_known
      @days = (days || DEFAULT_DAYS).to_i
      @include_globs = Array(include_globs)
      @exclude_globs = Array(exclude_globs)
      @described_by = described_by
      @previous = previous
      @logger = logger
    end

    def base
      "#{@url}#{@baseurl}"
    end

    def build(now: Time.now.utc)
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      now = now.utc
      now_s = StaticResourceSync.w3c(now)

      found = collect_files
      current = {}
      found.each do |rel, f|
        st = File.stat(f)
        current[rel] = { "md5" => Digest::MD5.file(f).hexdigest, "length" => st.size }
      end

      prev = load_previous
      old_res = prev ? prev["resources"] : {}
      old_changes = prev ? prev["changes"] : []
      old_from = prev ? prev["from"] : nil

      changes = []
      resources = {}
      current.each do |rel, cur|
        p_entry = old_res[rel]
        if prev.nil?
          resources[rel] = cur.merge("lastmod" => now_s)
        elsif p_entry.nil?
          resources[rel] = cur.merge("lastmod" => now_s)
          changes << { "path" => rel, "change" => "created", "datetime" => now_s }
        elsif p_entry["md5"] != cur["md5"]
          resources[rel] = cur.merge("lastmod" => now_s)
          changes << { "path" => rel, "change" => "updated", "datetime" => now_s }
        else
          resources[rel] = cur.merge("lastmod" => p_entry["lastmod"] || now_s)
        end
      end

      if prev
        old_res.each_key do |rel|
          changes << { "path" => rel, "change" => "deleted", "datetime" => now_s } unless current.key?(rel)
        end
      end

      cutoff = now - (@days * 86_400)
      log = (old_changes + changes).select do |c|
        Time.parse(c["datetime"]) >= cutoff
      rescue ArgumentError
        false
      end
      started = if old_from && !old_from.empty?
                  begin
                    [Time.parse(old_from).utc, cutoff].max
                  rescue ArgumentError
                    now
                  end
                else
                  now
                end
      started_s = StaticResourceSync.w3c(started)

      if resources.size > MAX_URLS
        raise "static_resourcesync: #{resources.size} URLs exceeds #{MAX_URLS}; resourcelist index not implemented"
      end

      write_xml_files(resources, log, started_s, now_s)

      counts = categorize(resources.keys)
      elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(2)
      summary = "#{resources.size} URLs (#{counts.map { |k, v| "#{k} #{v}" }.join(', ')}); " \
                "#{prev ? "changes this build: #{changes.size}" : 'baseline recorded, change list empty'}; " \
                "#{elapsed}s"
      log_info(summary)
      { resources: resources, changes: changes, log: log, counts: counts, baseline: prev.nil? }
    end

    def collect_files
      excluded = {}
      @exclude_globs.each do |pattern|
        pats = pattern.end_with?("/**") ? [pattern, "#{pattern}/*"] : [pattern]
        pats.each do |p|
          Dir.glob(File.join(@dest, p)).each { |f| excluded[f] = true }
        end
      end

      found = {}
      @include_globs.each do |pattern|
        Dir.glob(File.join(@dest, pattern)).each do |f|
          next unless File.file?(f)
          next if excluded[f]

          rel = f.delete_prefix("#{@dest}/")
          found[rel] = f
        end
      end
      found.sort.to_h
    end

    private

    def load_previous
      env_dir = ENV["RESOURCESYNC_PREVIOUS_DIR"].to_s.strip
      if !env_dir.empty?
        return nil if env_dir == "none"

        return load_previous_from_dir(env_dir)
      end

      case @previous.to_s
      when "", "none", "false"
        nil
      when "live"
        load_previous_from_live
      else
        load_previous_from_dir(@previous.to_s)
      end
    end

    def load_previous_from_dir(dir_path)
      rl_path = File.join(dir_path, "resourcelist.xml")
      return nil unless File.file?(rl_path)

      resources = StaticResourceSync.parse_resourcelist(File.read(rl_path), baseurl: @baseurl)
      return nil unless resources

      cl_path = File.join(dir_path, "changelist.xml")
      cl = File.file?(cl_path) ? StaticResourceSync.parse_changelist(File.read(cl_path), baseurl: @baseurl) : { "from" => nil, "changes" => [] }
      { "resources" => resources, "from" => cl["from"], "changes" => cl["changes"] }
    end

    def load_previous_from_live
      rl_url = "#{base}/#{@dir}/resourcelist.xml"
      rl_xml = StaticResourceSync.fetch_url(rl_url)
      unless rl_xml
        log_info("previous resourcelist not fetched from #{rl_url}; starting baseline")
        return nil
      end

      resources = StaticResourceSync.parse_resourcelist(rl_xml, baseurl: @baseurl)
      unless resources
        log_warn("could not parse previous resourcelist from #{rl_url}; starting baseline")
        return nil
      end

      cl_url = "#{base}/#{@dir}/changelist.xml"
      cl_xml = StaticResourceSync.fetch_url(cl_url)
      cl = StaticResourceSync.parse_changelist(cl_xml, baseurl: @baseurl)
      { "resources" => resources, "from" => cl["from"], "changes" => cl["changes"] }
    end

    def write_xml_files(resources, log, started_s, now_s)
      hdr = %(<?xml version="1.0" encoding="UTF-8"?>\n)
      url_of = ->(rel) { "#{base}/#{StaticResourceSync.encode_path(rel)}" }

      desc_rel = @well_known ? ".well-known/resourcesync" : "#{@dir}/description.xml"
      desc_url = "#{base}/#{desc_rel}"
      cap_rel = "#{@dir}/capabilitylist.xml"
      cap_url = "#{base}/#{cap_rel}"
      rl_rel = "#{@dir}/resourcelist.xml"
      cl_rel = "#{@dir}/changelist.xml"

      describedby_line = build_describedby_line

      write_file(
        desc_rel,
        "#{hdr}<urlset #{NS}>\n" \
        "  <rs:md capability=\"description\"/>\n" \
        "#{describedby_line}" \
        "  <url>\n" \
        "    <loc>#{StaticResourceSync.esc(cap_url)}</loc>\n" \
        "    <rs:md capability=\"capabilitylist\"/>\n" \
        "  </url>\n" \
        "</urlset>\n"
      )

      write_file(
        cap_rel,
        "#{hdr}<urlset #{NS}>\n" \
        "  <rs:md capability=\"capabilitylist\"/>\n" \
        "  <rs:ln rel=\"up\" href=\"#{StaticResourceSync.esc(desc_url)}\"/>\n" \
        "  <url>\n" \
        "    <loc>#{StaticResourceSync.esc("#{base}/#{rl_rel}")}</loc>\n" \
        "    <rs:md capability=\"resourcelist\"/>\n" \
        "  </url>\n" \
        "  <url>\n" \
        "    <loc>#{StaticResourceSync.esc("#{base}/#{cl_rel}")}</loc>\n" \
        "    <rs:md capability=\"changelist\"/>\n" \
        "  </url>\n" \
        "</urlset>\n"
      )

      rl = +"#{hdr}<urlset #{NS}>\n" \
            "  <rs:md capability=\"resourcelist\" at=\"#{now_s}\"/>\n" \
            "  <rs:ln rel=\"up\" href=\"#{StaticResourceSync.esc(cap_url)}\"/>\n"
      resources.each do |rel, r|
        rl << "  <url>\n" \
              "    <loc>#{StaticResourceSync.esc(url_of.call(rel))}</loc>\n" \
              "    <lastmod>#{r['lastmod']}</lastmod>\n" \
              "    <rs:md hash=\"md5:#{r['md5']}\" length=\"#{r['length']}\" type=\"#{StaticResourceSync.mime_type(rel)}\"/>\n" \
              "  </url>\n"
      end
      rl << "</urlset>\n"
      write_file(rl_rel, rl)

      cl = +"#{hdr}<urlset #{NS}>\n" \
            "  <rs:md capability=\"changelist\" from=\"#{started_s}\" until=\"#{now_s}\"/>\n" \
            "  <rs:ln rel=\"up\" href=\"#{StaticResourceSync.esc(cap_url)}\"/>\n"
      log.sort_by { |c| [c["datetime"], c["path"]] }.each do |c|
        cl << "  <url>\n" \
              "    <loc>#{StaticResourceSync.esc(url_of.call(c['path']))}</loc>\n" \
              "    <lastmod>#{c['datetime']}</lastmod>\n" \
              "    <rs:md change=\"#{StaticResourceSync.esc(c['change'])}\" datetime=\"#{StaticResourceSync.esc(c['datetime'])}\"/>\n" \
              "  </url>\n"
      end
      cl << "</urlset>\n"
      write_file(cl_rel, cl)
    end

    def build_describedby_line
      return "" if @described_by.nil? || @described_by.to_s.strip.empty?

      val = @described_by.to_s.strip
      href = if val.match?(%r{\Ahttps?://}i)
               val
             else
               rel = val.sub(%r{\A/+}, "")
               return "" unless File.file?(File.join(@dest, rel))

               "#{base}/#{StaticResourceSync.encode_path(rel)}"
             end
      "  <rs:ln rel=\"describedby\" href=\"#{StaticResourceSync.esc(href)}\"/>\n"
    end

    def write_file(rel, content)
      path = File.join(@dest, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end

    def categorize(paths)
      counts = Hash.new(0)
      paths.each do |rel|
        kind = if rel.start_with?("items/")
                 "items"
               elsif rel.start_with?("iiif/")
                 "manifests"
               elsif rel.start_with?("objects/", "files/")
                 "images"
               else
                 "data"
               end
        counts[kind] += 1
      end
      counts
    end

    def log_info(msg)
      @logger&.info("ResourceSync:", msg)
    end

    def log_warn(msg)
      @logger&.warn("ResourceSync:", msg)
    end
  end
end
