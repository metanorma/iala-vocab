#!/usr/bin/env ruby
require "yaml"
require "json"
require "fileutils"
require "nokogiri"

HISTORIC_INDEX = "reference-docs/scraped/editions/iala-historic/index.json"
DATASETS = %w[iala-1970-89 iala-2009 iala-2012 iala-2015 iala-2016 iala-2017 iala-2018 iala-2022 iala-2023].freeze
EDITION_YEARS = {
  "iala-1970-89" => 1989, "iala-2009" => 2009, "iala-2012" => 2012,
  "iala-2015" => 2015, "iala-2016" => 2016, "iala-2017" => 2017,
  "iala-2018" => 2018, "iala-2022" => 2022, "iala-2023" => 2023,
}.freeze

def load_indices
  hash = {}
  DATASETS.each do |edition|
    path = "reference-docs/scraped/editions/#{edition}/index.json"
    next unless File.exist?(path)
    JSON.parse(File.read(path)).each { |e| (hash[e["title"]] ||= []) << edition }
  end
  hash
end

INDICES = load_indices.freeze

def active_target_for(stripped_title)
  candidates = INDICES[stripped_title] || []
  return nil if candidates.empty?
  latest = candidates.max_by { |ed| EDITION_YEARS[ed] || 0 }
  edition = latest
  idx_path = "reference-docs/scraped/editions/#{edition}/index.json"
  idx = JSON.parse(File.read(idx_path))
  entry = idx.find { |e| e["title"] == stripped_title }
  termid = entry && (entry["numeric_code"] || entry["title"].downcase.gsub(/[^a-z0-9]+/, "-").gsub(/^-|-$/, ""))
  [edition, termid]
end

def parse_sections(wikitext)
  sections = []
  current = nil
  wikitext.lines.each do |raw|
    line = raw.chomp
    if (m = line.match(/\A==([^=]+)==\z/))
      current = { heading: m[1].strip, code: nil, body_lines: [] }
      sections << current
    elsif current
      current[:body_lines] << line
    end
  end
  sections
end

def extract_code_and_designation(section)
  body = section[:body_lines].map(&:strip).reject(&:empty?)
  code = nil
  body = body.reject do |line|
    if (m = line.match(/\A'''([\w-]+)'''\z/)) && code.nil?
      code = m[1]
      true
    else
      false
    end
  end
  [code, body]
end

def split_notes(lines)
  notes = []
  defs = []
  alt_designation = nil
  current_chunk = []

  lines.each do |line|
    cleaned = line.gsub(/'''/, "").gsub(/''/, "").strip
    if (m = cleaned.match(/\AAlternative term:\s*(.+)\z/))
      alt_designation = m[1].strip
      next
    end
    if (m = cleaned.match(/\ANote:\s*(.+)\z/))
      notes << m[1].strip
      next
    end
    if cleaned.match?(/\APlease note that this is the term/) ||
       cleaned.match?(/\(VTS\d+\//) ||
       cleaned.match?(/\ACategory:/) ||
       cleaned.match?(/\A\[\[/) ||
       cleaned.match?(/\A\{\{/) ||
       cleaned.empty?
      next
    end
    current_chunk << cleaned
  end

  defs = current_chunk
  [alt_designation, notes, defs]
end

def build_localized_doc(termid, designation, alt_designation, definition_text, notes, page_url, original_title)
  terms = [{ "type" => "expression", "designation" => designation, "normative_status" => "preferred" }]
  if alt_designation
    terms << { "type" => "expression", "designation" => alt_designation, "normative_status" => "admitted" }
  end

  doc = {
    "id" => "#{termid}-eng",
    "termid" => termid,
    "data" => { "language_code" => "eng" },
    "terms" => terms,
    "definition" => [{ "content" => definition_text }],
    "sources" => [{ "type" => "authoritative", "origin" => { "ref" => "IALA Dictionary" } }]
  }
  doc["notes"] = notes.map { |n| { "content" => n } } unless notes.empty?
  doc["annotations"] = [{ "content" => "Discontinued entry from #{original_title} (#{page_url})" }]
  doc
end

def build_managed_doc(termid, edition, target_edition, target_termid)
  managed = {
    "id" => termid,
    "data" => {
      "identifier" => termid,
      "domains" => [{
        "source" => "urn:iala:dictionary:#{edition.sub('iala-', '')}",
        "concept_id" => "section-historic",
        "ref_type" => "section"
      }]
    },
    "status" => "retired",
    "sources" => [{
      "type" => "authoritative",
      "origin" => { "ref" => "IALA Dictionary", "link" => "" }
    }]
  }

  if target_edition && target_termid
    managed["related"] = [{
      "type" => "retired_by",
      "ref" => {
        "source" => "urn:iala:dictionary:#{target_edition.sub('iala-', '')}",
        "concept_id" => target_termid
      }
    }]
  end
  managed["dates"] = [
    { "type" => "accepted", "date" => "1970-1989" },
    { "type" => "retired",  "date" => "2016" }
  ]
  managed
end

def write_concept_yaml(path, docs)
  FileUtils.mkdir_p(File.dirname(path))
  content = docs.map { |d| YAML.dump(d) }.join
  File.write(path, content)
end

def append_retires_to_target(target_edition, target_termid, source_edition, source_termid)
  return unless target_edition && target_termid
  target_path = "datasets/#{target_edition}/concepts/#{target_termid}.yaml"
  return unless File.exist?(target_path)

  docs = YAML.load_stream(File.read(target_path))
  return if docs.empty?
  managed = docs[0]
  managed["related"] ||= []
  entry = {
    "type" => "retires",
    "ref" => {
      "source" => "urn:iala:dictionary:#{source_edition.sub('iala-', '')}",
      "concept_id" => source_termid
    }
  }
  return if managed["related"].any? { |r| r["type"] == "retires" &&
                                           r.dig("ref", "concept_id") == source_termid &&
                                           r.dig("ref", "source") == entry.dig("ref", "source") }
  managed["related"] << entry
  File.write(target_path, docs.map { |d| YAML.dump(d) }.join)
end

abort "Historic index not found: #{HISTORIC_INDEX}" unless File.exist?(HISTORIC_INDEX)

index = JSON.parse(File.read(HISTORIC_INDEX))
stats = { scanned: 0, skipped_superseded: 0, discontinued_pages: 0, sections_emitted: 0, no_target: 0, errors: 0 }

index.each do |entry|
  stats[:scanned] += 1
  title = entry["title"]

  if title.end_with?("(Superseded)")
    stats[:skipped_superseded] += 1
    next
  end

  next unless title.end_with?("(Discontinued)")
  stats[:discontinued_pages] += 1

  stripped = title.sub(/\s*\(Discontinued\)\z/, "")
  target = active_target_for(stripped)
  target_edition, target_termid = target || [nil, nil]
  unless target_edition
    warn "  no active target for #{stripped.inspect}"
    stats[:no_target] += 1
  end

  page_path = "reference-docs/scraped/editions/iala-historic/#{entry['page_file']}"
  page = JSON.parse(File.read(page_path))
  wikitext = page["wikitext"] || ""
  page_url = "https://www.iala.int/wiki/dictionary/index.php/#{title.tr(' ', '_')}"

  sections = parse_sections(wikitext)
  sections.each do |section|
    code, body = extract_code_and_designation(section)
    unless code
      warn "  no numeric code in section #{section[:heading].inspect} of #{title}"
      next
    end

    alt_designation, notes, defs = split_notes(body)
    definition_text = defs.join("\n\n")
    next if definition_text.strip.empty?

    designation = section[:heading]
    termid = code
    source_edition = "iala-1970-89"
    suffix = ""
    n = 1
    while File.exist?("datasets/#{source_edition}/concepts/#{termid}#{suffix}.yaml")
      n += 1
      suffix = "-#{n}"
    end
    final_termid = "#{termid}#{suffix}"

    managed = build_managed_doc(final_termid, source_edition, target_edition, target_termid)
    managed["sources"][0]["origin"]["link"] = page_url
    localized = build_localized_doc(final_termid, designation, alt_designation, definition_text, notes, page_url, title)

    out_path = "datasets/#{source_edition}/concepts/#{final_termid}.yaml"
    write_concept_yaml(out_path, [managed, localized])
    stats[:sections_emitted] += 1

    append_retires_to_target(target_edition, target_termid, source_edition, final_termid)
  end
rescue => e
  warn "  ERROR on #{entry['title']}: #{e.message}"
  stats[:errors] += 1
end

puts "Transform historic:"
stats.each { |k, v| puts "  #{k}: #{v}" }
