#!/usr/bin/env ruby
# Walks reference-docs/api-cache/*.json (root-level only), infers the
# MediaWiki action subdir from the JSON shape, and moves each file into
# api-cache/<subdir>/<hash>.json. Idempotent: files already in a subdir
# are not touched because the glob only matches the root.

require "fileutils"
require "json"

CACHE_ROOT = File.expand_path("../reference-docs/api-cache", __dir__)
SUBDIRS = %w[parse categorymembers content misc].freeze

def classify(json)
  if json["parse"]
    "parse"
  elsif json.dig("query", "categorymembers")
    "categorymembers"
  elsif json.dig("query", "pages")
    "content"
  else
    "misc"
  end
end

counts = Hash.new(0)

Dir.glob("#{CACHE_ROOT}/*.json").each do |path|
  entry = File.basename(path)

  begin
    json = JSON.parse(File.read(path))
  rescue JSON::ParserError
    warn "Skipping unparseable cache file: #{entry}"
    counts[:broken] += 1
    next
  end

  subdir = classify(json)
  target_dir = File.join(CACHE_ROOT, subdir)
  FileUtils.mkdir_p(target_dir)
  target = File.join(target_dir, entry)

  if File.exist?(target)
    warn "Skipping (target exists): #{subdir}/#{entry}"
    counts[:collision] += 1
    next
  end

  FileUtils.mv(path, target)
  counts[subdir] += 1
end

puts "Migrated api-cache files:"
SUBDIRS.each { |s| puts "  #{s}: #{counts[s]}" }
puts "  broken:    #{counts[:broken]}"    if counts[:broken]
puts "  collision: #{counts[:collision]}" if counts[:collision]
puts "Done."
