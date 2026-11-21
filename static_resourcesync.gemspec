# frozen_string_literal: true

require_relative "lib/static_resourcesync/version"

Gem::Specification.new do |spec|
  spec.name = "static_resourcesync"
  spec.version = StaticResourceSync::VERSION
  spec.authors = ["Satoru Nakamura"]
  spec.summary = "ResourceSync (ANSI/NISO Z39.99) for static Jekyll and CollectionBuilder sites"
  spec.description = "Publishes ResourceSync 1.1 files (Source Description, Capability List, Resource List, " \
                     "and Change List) at build time for static sites, with automatic <link rel=\"resourcesync\"> " \
                     "injection and stateless diffing against the live published site."
  spec.homepage = "https://github.com/nakamura196/static_resourcesync"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "scripts/*", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]
end
