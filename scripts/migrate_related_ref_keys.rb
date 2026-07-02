#!/usr/bin/env ruby
# Walks datasets/*/concepts/*.yaml multi-doc streams and renames
# related[].ref.concept_id -> related[].ref.id (the glossarist v3
# canonical form for a Citation.ref, per concept-model/schemas/v3/
# examples/06-related-relationships.yaml).
#
# Leaves data.domains[].concept_id untouched (ConceptReference uses
# concept_id; Citation.ref uses id — two different shapes).
#
# Idempotent: re-running is a no-op once renamed.

require "yaml"

ROOT = File.expand_path("../datasets", __dir__)
Dir.glob("#{ROOT}/*/concepts/*.yaml").each do |path|
  docs = YAML.load_stream(File.read(path))
  next if docs.empty?

  managed = docs[0]
  related = managed && managed["related"]
  next unless related.is_a?(Array)

  changed = false
  related.each do |r|
    ref = r.is_a?(Hash) ? r["ref"] : nil
    next unless ref.is_a?(Hash) && ref.key?("concept_id")

    ref["id"] = ref.delete("concept_id")
    changed = true
  end

  next unless changed

  File.write(path, docs.map { |d| YAML.dump(d) }.join)
end

puts "Done."
