#!/usr/bin/env ruby
# Walks datasets/*/concepts/*.yaml multi-doc streams and rewrites
# `sources[].origin.ref: "string"` to `sources[].origin.ref: { source: "string" }`.
#
# Per glossarist v3 schema (concept-model/schemas/v3/examples/07-sources.yaml),
# Citation.ref is always a hash. Older transform scripts emitted a bare
# string for the IALA Dictionary ref, which the glossarist-ruby library
# refuses to load.
#
# Idempotent: a ref that is already a Hash is left alone.

require "yaml"

ROOT = File.expand_path("../datasets", __dir__)
migrated = 0
files_changed = 0

Dir.glob("#{ROOT}/*/concepts/*.yaml").each do |path|
  docs = YAML.load_stream(File.read(path))
  changed = false

  docs.each do |doc|
    next unless doc.is_a?(Hash)
    sources = doc["sources"]
    next unless sources.is_a?(Array)

    sources.each do |s|
      origin = s.is_a?(Hash) ? s["origin"] : nil
      next unless origin.is_a?(Hash)

      ref = origin["ref"]
      next unless ref.is_a?(String)

      origin["ref"] = { "source" => ref }
      migrated += 1
      changed = true
    end
  end

  next unless changed

  File.write(path, docs.map { |d| YAML.dump(d) }.join)
  files_changed += 1
end

puts "Migrated #{migrated} origin.ref strings across #{files_changed} files."
