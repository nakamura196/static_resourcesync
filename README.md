# static_resourcesync

ResourceSync (ANSI/NISO Z39.99-2017, ResourceSync 1.1) for static Jekyll and [CollectionBuilder](https://collectionbuilder.github.io/) sites — a static-site replacement for OAI-PMH, with no server software and no committed state file.

At build time, the plugin writes the four ResourceSync documents and automatically inserts `<link rel="resourcesync" href=".../capabilitylist.xml">` into `<head>` of every HTML page:

- **Source Description**: `/.well-known/resourcesync` (when served at the host root) or `/<baseurl>/resourcesync/description.xml` (when served under a subpath)
- **Capability List**: `/<baseurl>/resourcesync/capabilitylist.xml`
- **Resource List**: `/<baseurl>/resourcesync/resourcelist.xml` (item pages, IIIF manifests, data exports, images, each with `lastmod`, `md5`, `length`, `type`)
- **Change List**: `/<baseurl>/resourcesync/changelist.xml` (`created`, `updated`, `deleted` over the last 90 days)

## Stateless diffing across CI builds

In CI (such as GitHub Actions), every build starts from a fresh checkout. By default (`previous: live`), the plugin fetches the currently published `resourcelist.xml` and `changelist.xml` over HTTP, compares MD5 hashes per URL, keeps `lastmod` unchanged when a file's MD5 is unchanged, and appends `created` / `updated` / `deleted` events to the Change List.

If the site has not been published yet or the fetch fails, the build does not fail: it starts a clean baseline with an empty Change List.

## Installation (CollectionBuilder / Jekyll)

Add the gem to `Gemfile`:

```ruby
group :jekyll_plugins do
  gem "static_resourcesync", git: "https://github.com/nakamura196/static_resourcesync.git", require: "static_resourcesync/jekyll"
end
```

For a standard CollectionBuilder-CSV site, **no `_config.yml` changes are required**. Optional settings under `static_resourcesync:`:

```yaml
static_resourcesync:
  enabled: true                 # set false in a secondary language build (e.g. _config.en.yml)
  link_href: /site/resourcesync/capabilitylist.xml  # optional: keep <link rel="resourcesync"> when enabled: false
  dir: resourcesync             # output folder inside _site
  well_known: false             # default: true when baseurl is empty, false otherwise
  days: 90                      # days of history kept in changelist.xml
  previous: live                # "live", "none", or a local directory path
  inject_link: true             # auto-insert <link rel="resourcesync"> into HTML <head>
  described_by: data.html       # rel="describedby" target in Source Description (if present)
  include:
    - "items/*.html"
    - "iiif/**/*manifest*.json"
    - "iiif/collection/**/*.json"
    - "assets/data/*"
    - "objects/**/*.{jpg,jpeg,png,webp,JPG,JPEG,PNG,WEBP}"
    - "files/original/**/*.{jpg,jpeg,png,webp,JPG,JPEG,PNG,WEBP}"
  exclude:
    - "objects/iiif/**"
```

### Local testing without hitting the live site

Set `RESOURCESYNC_PREVIOUS_DIR` to test incremental builds locally:

```sh
# 1st build (baseline)
RESOURCESYNC_PREVIOUS_DIR=none bundle exec jekyll build

# Copy the generated lists, then run a 2nd build (0 changes)
cp -r _site/resourcesync /tmp/rs-prev
RESOURCESYNC_PREVIOUS_DIR=/tmp/rs-prev bundle exec jekyll build
```

## Demo harvester

`scripts/resourcesync_harvest.py` is a minimal ResourceSync 1.1 harvester using only the Python 3 standard library. It verifies the MD5 hash and byte length of every downloaded file.

```sh
# Initial sync (use --limit for a quick demo)
python3 scripts/resourcesync_harvest.py https://example.org/site/ ./mirror --limit 10

# Subsequent incremental sync (reads changelist.xml; downloads created/updated, removes deleted)
python3 scripts/resourcesync_harvest.py https://example.org/site/ ./mirror
```

## Development

```sh
bundle install
bundle exec rake test
```

## License

MIT
