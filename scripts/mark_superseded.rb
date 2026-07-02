#!/usr/bin/env ruby
require "json"
require "uri"
require_relative "glossarist_helpers"

EDITIONS = %w[iala-1970-89 iala-2009 iala-2012 iala-2015 iala-2016 iala-2017 iala-2018 iala-2022 iala-2023].freeze
EDITION_YEARS = {
  "iala-1970-89" => 1989, "iala-2009" => 2009, "iala-2012" => 2012,
  "iala-2015" => 2015, "iala-2016" => 2016, "iala-2017" => 2017,
  "iala-2018" => 2018, "iala-2022" => 2022, "iala-2023" => 2023,
}.freeze

def urn_for(edition)
  "urn:iala:dictionary:#{edition.sub('iala-', '')}"
end

# Build index of (edition, title) → entry by scraping the cached indices.
def load_indices
  hash = {}
  EDITIONS.each do |edition|
    path = "reference-docs/scraped/editions/#{edition}/index.json"
    next unless File.exist?(path)
    idx = JSON.parse(File.read(path))
    idx.each { |entry| (hash[entry["title"]] ||= []) << [edition, entry] }
  end
  hash
end

INDICES = load_indices.freeze

def active_target_for(stripped_title, source_edition)
  candidates = INDICES[stripped_title] || []
  eligible = candidates.reject { |ed, _| ed == source_edition }
  return nil if eligible.empty?

  latest = eligible.max_by { |ed, _| EDITION_YEARS[ed] || 0 }
  edition_id = latest[0]
  entry = latest[1]
  termid = entry["numeric_code"] || entry["title"].downcase.gsub(/[^a-z0-9]+/, "-").gsub(/^-|-$/, "")
  [edition_id, termid]
end

def each_concept_file
  EDITIONS.each do |edition|
    Dir.glob("datasets/#{edition}/concepts/*.yaml").each { |path| yield edition, path }
  end
end

def has_related?(managed, type, source, id)
  return false unless managed.related
  managed.related.any? do |r|
    r.type == type && r.ref&.source == source && r.ref&.id == id
  end
end

def has_date?(managed, type, date)
  return false unless managed.dates
  # V3::ConceptDate types `date` as :string, so year-only strings (e.g.
  # "2023") round-trip cleanly. Compare both type and date.
  managed.dates.any? { |d| d.type == type && d.date == date.to_s }
end

stats = { scanned: 0, superseded_marked: 0, edges_added: 0, missing_target: 0, errors: 0 }
superseded_links = []

each_concept_file do |edition, path|
  stats[:scanned] += 1
  concept = GlossaristHelpers.read_concept_file(path)
  next unless concept && concept.managed
  managed = concept.managed

  link = managed.sources&.flat_map { |s| s.origin&.link }.compact.first
  next unless link && link.end_with?("_(Superseded)")

  base = File.basename(URI.parse(link).path).sub(/_\(Superseded\)\z/, "").tr("_", " ")

  target = active_target_for(base, edition)
  unless target
    warn "  no active target for #{base.inspect} (in #{edition})"
    stats[:missing_target] += 1
    next
  end

  target_edition, target_termid = target
  dirty = false

  if managed.status != "superseded"
    managed.status = "superseded"
    stats[:superseded_marked] += 1
    dirty = true
  end

  unless has_related?(managed, "superseded_by", urn_for(target_edition), target_termid)
    managed.related << Glossarist::V3::RelatedConcept.new(
      type: "superseded_by",
      ref: Glossarist::V3::ConceptRef.new(source: urn_for(target_edition), id: target_termid),
    )
    stats[:edges_added] += 1
    dirty = true
  end

  target_year = EDITION_YEARS[target_edition]
  if target_year && !has_date?(managed, "retired", target_year)
    managed.dates << Glossarist::V3::ConceptDate.new(type: "retired", date: target_year.to_s)
    dirty = true
  end

  if dirty
    GlossaristHelpers.write_concept_file(path, concept)
    superseded_links << { source: edition, source_termid: managed.id,
                          target: target_edition, target_termid: target_termid }
  end
rescue => e
  warn "  ERROR on #{path}: #{e.message}"
  stats[:errors] += 1
end

# Write inverse supersedes edges on the active targets.
superseded_links.each do |link|
  target_path = "datasets/#{link[:target]}/concepts/#{link[:target_termid]}.yaml"
  next unless File.exist?(target_path)

  concept = GlossaristHelpers.read_concept_file(target_path)
  next unless concept && concept.managed

  if has_related?(concept.managed, "supersedes", urn_for(link[:source]), link[:source_termid])
    next
  end

  concept.managed.related << Glossarist::V3::RelatedConcept.new(
    type: "supersedes",
    ref: Glossarist::V3::ConceptRef.new(source: urn_for(link[:source]), id: link[:source_termid]),
  )
  GlossaristHelpers.write_concept_file(target_path, concept)
rescue => e
  warn "  ERROR on inverse #{target_path}: #{e.message}"
  stats[:errors] += 1
end

puts "Mark superseded:"
stats.each { |k, v| puts "  #{k}: #{v}" }