# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

class TestStaticResourceSync < Minitest::Test
  def setup
    @orig_env = ENV["RESOURCESYNC_PREVIOUS_DIR"]
    ENV.delete("RESOURCESYNC_PREVIOUS_DIR")
  end

  def teardown
    if @orig_env.nil?
      ENV.delete("RESOURCESYNC_PREVIOUS_DIR")
    else
      ENV["RESOURCESYNC_PREVIOUS_DIR"] = @orig_env
    end
  end

  def write_sample_site(dir)
    FileUtils.mkdir_p(File.join(dir, "items"))
    FileUtils.mkdir_p(File.join(dir, "iiif/3/item01"))
    FileUtils.mkdir_p(File.join(dir, "assets/data"))
    FileUtils.mkdir_p(File.join(dir, "files/original/vol1"))
    FileUtils.mkdir_p(File.join(dir, "objects/iiif/3/item01/full/256,256/0"))

    File.write(File.join(dir, "data.html"), "<html><body>data</body></html>")
    File.write(File.join(dir, "items/item01.html"), "<html><body>item 1</body></html>")
    File.write(File.join(dir, "items/item02.html"), "<html><body>item 2</body></html>")
    File.write(File.join(dir, "iiif/3/item01/manifest.json"), '{"id":"item01"}')
    File.write(File.join(dir, "assets/data/metadata.csv"), "objectid,title\nitem01,One\n")
    File.write(File.join(dir, "files/original/vol1/img01.jpg"), "fakejpegdata")
    File.write(File.join(dir, "objects/iiif/3/item01/full/256,256/0/default.jpg"), "tiledata")
  end

  def test_baseline_and_incremental_builds
    Dir.mktmpdir do |tmp|
      site_dir = File.join(tmp, "_site")
      prev_dir = File.join(tmp, "prev")
      write_sample_site(site_dir)

      t1 = Time.utc(2026, 11, 21, 10, 0, 0)
      b1 = StaticResourceSync::Builder.new(
        dest: site_dir,
        url: "https://example.org",
        baseurl: "/lda",
        previous: "none"
      )
      res1 = b1.build(now: t1)

      assert res1[:baseline]
      assert_equal 5, res1[:resources].size
      refute res1[:resources].key?("objects/iiif/3/item01/full/256,256/0/default.jpg")
      assert File.file?(File.join(site_dir, "resourcesync/description.xml"))
      refute File.exist?(File.join(site_dir, ".well-known/resourcesync"))
      assert_empty res1[:changes]

      # Save previous lists and rebuild without changes
      FileUtils.cp_r(File.join(site_dir, "resourcesync"), prev_dir)
      t2 = Time.utc(2026, 11, 21, 11, 0, 0)
      b2 = StaticResourceSync::Builder.new(
        dest: site_dir,
        url: "https://example.org",
        baseurl: "/lda",
        previous: prev_dir
      )
      res2 = b2.build(now: t2)

      refute res2[:baseline]
      assert_empty res2[:changes]
      assert_equal "2026-11-21T10:00:00Z", res2[:resources]["items/item01.html"]["lastmod"]

      # Update item01, add item03, delete item02
      FileUtils.rm_rf(prev_dir)
      FileUtils.cp_r(File.join(site_dir, "resourcesync"), prev_dir)
      File.write(File.join(site_dir, "items/item01.html"), "<html><body>item 1 updated</body></html>")
      File.write(File.join(site_dir, "items/item03.html"), "<html><body>item 3</body></html>")
      FileUtils.rm(File.join(site_dir, "items/item02.html"))

      t3 = Time.utc(2026, 11, 22, 10, 0, 0)
      res3 = b2.build(now: t3)
      by_path = res3[:changes].each_with_object({}) { |c, h| h[c["path"]] = c["change"] }
      assert_equal({
        "items/item01.html" => "updated",
        "items/item03.html" => "created",
        "items/item02.html" => "deleted"
      }, by_path)
      assert_equal "2026-11-22T10:00:00Z", res3[:resources]["items/item01.html"]["lastmod"]
      assert_equal "2026-11-21T10:00:00Z", res3[:resources]["assets/data/metadata.csv"]["lastmod"]
    end
  end

  def test_well_known_when_no_baseurl
    Dir.mktmpdir do |tmp|
      write_sample_site(tmp)
      builder = StaticResourceSync::Builder.new(
        dest: tmp,
        url: "https://example.org",
        baseurl: "",
        previous: "none"
      )
      builder.build(now: Time.utc(2026, 11, 21, 10, 0, 0))
      assert File.file?(File.join(tmp, ".well-known/resourcesync"))
      cap = File.read(File.join(tmp, "resourcesync/capabilitylist.xml"))
      assert_includes cap, 'href="https://example.org/.well-known/resourcesync"'
    end
  end
end
