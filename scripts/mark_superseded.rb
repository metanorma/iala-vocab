#!/usr/bin/env ruby
require "yaml"
require "json"
require "uri"

EDITIONS = %w[iala-1970-89 iala-2009 iala-2012 iala-2015 iala-2016 iala-2017 iala-2018 iala-2022 iala-2023].freeze
EDITION_YEARS = {
  "iala-1970-89" => 1989, "iala-2009" => 2009, "iala-2012" => 2012,
  "iala-2015" => 2015, "iala-2016" => 2016, "iala-2017" => 2017,
  "iala-2018" => 2018, "iala-2022" => 2022, "iala-2023" => 2023,
}.freeze

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
    Dir.glob("datasets/#{edition}/concepts/*.yaml").each do |path|
      yield edition, path
    end
  end
end

def read_docs(path)
  YAML.load_stream(File.read(path))
rescue => e
  warn "  parse error in #{path}: #{e.message}"
  []
end

def write_docs(path, docs)
  content = docs.map { |d| YAML.dump(d) }.join
  File.write(path, content)
end

def related_entry(type, edition, termid)
  { "type" => type, "ref" => { "source" => "urn:iala:dictionary:#{edition.sub('iala-', '')}",
                                "concept_id" => termid } }
end

def append_related(managed, entry)
  return false if managed.nil?
  managed["related"] ||= []
  return false if managed["related"].any? { |r| r["type"] == entry["type"] &&
                                                  r.dig("ref", "concept_id") == entry.dig("ref", "concept_id") &&
                                                  r.dig("ref", "source") == entry.dig("ref", "source") }
  managed["related"] << entry
  true
end

def append_date(managed, type, date)
  return false if managed.nil?
  managed["dates"] ||= []
  return false if managed["dates"].any? { |d| d["type"] == type && d["date"] == date }
  managed["dates"] << { "type" => type, "date" => date.to_s }
  true
end

stats = { scanned: 0, superseded_marked: 0, edges_added: 0, missing_target: 0, errors: 0 }
superseded_links = []

each_concept_file do |edition, path|
  stats[:scanned] += 1
  docs = read_docs(path)
  next if docs.empty?
  managed = docs[0]
  next unless managed && managed["sources"]

  link = managed["sources"].map { |s| s.dig("origin", "link") }.compact.first
  next unless link && link.end_with?("_(Superseded)")

  base = File.basename(URI.parse(link).path).sub(/_\(Superseded\)\z/, "").tr("_", " ")

  target = active_target_for(base, edition)
  unless target
    warn "  no active target for #{base.inspect} (in #{edition})"
    stats[:missing_target] += 1
    next
  end

  target_edition, target_termid = target
  changed = false

  if managed["status"] != "superseded"
    managed["status"] = "superseded"
    stats[:superseded_marked] += 1
    changed = true
  end

  if append_related(managed, related_entry("superseded_by", target_edition, target_termid))
    stats[:edges_added] += 1
    changed = true
  end

  target_year = EDITION_YEARS[target_edition]
  if target_year && append_date(managed, "retired", target_year)
    changed = true
  end

  write_docs(path, docs) if changed
  superseded_links << { source: edition, source_termid: managed["id"],
                        target: target_edition, target_termid: target_termid }
rescue => e
  warn "  ERROR on #{path}: #{e.message}"
  stats[:errors] += 1
end

superseded_links.each do |link|
  target_path = "datasets/#{link[:target]}/concepts/#{link[:target_termid]}.yaml"
  next unless File.exist?(target_path)

  docs = read_docs(target_path)
  next if docs.empty?

  changed = append_related(docs[0], related_entry("supersedes", link[:source], link[:source_termid]))
  write_docs(target_path, docs) if changed
rescue => e
  warn "  ERROR on inverse #{target_path}: #{e.message}"
  stats[:errors] += 1
end

puts "Mark superseded:"
stats.each { |k, v| puts "  #{k}: #{v}" }
