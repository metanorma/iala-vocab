#!/usr/bin/env ruby
# Walks datasets/*/concepts/*.yaml multi-doc streams and, for each
# localized concept doc (doc 1+), moves top-level fields that canonically
# belong under `data:` per glossarist v3 schema
# (concept-model/schemas/v3/examples/01-minimal-localized.yaml).
#
# Per v3 canonical shape, fields like `terms`, `definition`, `notes`,
# `sources`, etc. live under `data:`, not at the top level of the
# localized doc. The previous shape worked because concept-browser's
# generate-data.mjs explicitly merges top-level fields into data; this
# migration moves us to the canonical v3 shape that the glossarist-ruby
# library expects.
#
# Top-level keys preserved: `id`, `termid`. Everything else that v3
# allows under `data:` moves into data (overwriting only if not present).
# Idempotent: top-level keys that already moved are absent.

require "yaml"

LOCALIZED_FIELDS = %w[
  terms definition notes sources examples dates annotations references
  classification review_type entry_status release script system
  lineage_source_similarity review_date review_decision_date
  review_decision_event review_status review_decision review_decision_notes
  domain
].freeze

ROOT = File.expand_path("../datasets", __dir__)
moved_keys = 0
files_changed = 0

Dir.glob("#{ROOT}/*/concepts/*.yaml").each do |path|
  docs = YAML.load_stream(File.read(path))
  changed = false

  docs.drop(1).each do |doc|
    next unless doc.is_a?(Hash)

    data = (doc["data"] ||= {})

    LOCALIZED_FIELDS.each do |key|
      next unless doc.key?(key)
      # Move under data if not already there
      unless data.key?(key)
        data[key] = doc.delete(key)
        moved_keys += 1
        changed = true
      else
        # Already under data — drop top-level duplicate
        doc.delete(key)
        changed = true
      end
    end
  end

  next unless changed

  File.write(path, docs.map { |d| YAML.dump(d) }.join)
  files_changed += 1
end

puts "Moved #{moved_keys} top-level fields into data: across #{files_changed} files."