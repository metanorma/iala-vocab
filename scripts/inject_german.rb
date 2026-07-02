#!/usr/bin/env ruby
require "yaml"
require "json"
require "nokogiri"
require "fileutils"
require "glossarist"

TRANSLATIONS_DIR = "reference-docs/scraped/translations/deu"
DATASETS = %w[iala-1970-89 iala-2009 iala-2012 iala-2015 iala-2016 iala-2017 iala-2018 iala-2022 iala-2023]
SKIP_TITLES = ["TestPage"].freeze

# German citation markers. Source pages use:
#   "Quelle: C.I.E. (abgewandelt)"      — "Source: C.I.E. (modified)"
#   "Referenz: C.I.E. (angepasst)"      — "Reference: C.I.E. (adapted)"
#   "Reference: I.E.C. (modified)"      — English prefix on some pages
#   "C.I.E. (Auszug)"                  — bare attribution line, no prefix
CITATION_PREFIX_RE = /\A\s*(?:<br\s*\/?>[\s\n]*)*(?:Quelle|Referenz|Reference)\s*:\s*/i
BARE_CITATION_RE   = /\A\s*((?:C\.I\.E\.|I\.E\.C\.|ISO)(?:\s*\(.+\))?)\s*\z/
MODIFIED_RE        = /\((?:abgewandelt|angepasst|modified|adapted)\)/i

def extract_numeric_code(wikitext)
  m = wikitext&.match(/'''(\d+-\d+-\d+)/)
  m && m[1]
end

# Returns [designation, definition_body, sources_array].
# Sources: [{ ref_text:, modified: bool }, ...]
def extract_german_terms(html)
  doc = Nokogiri::HTML(html)
  doc.css(".LanguageLinks").each { |n| n.remove }
  doc.css(".mw-lingo-tooltip").each { |n| n.remove }
  doc.css("#toc").each { |n| n.remove }
  doc.css("i").each { |n| n.remove if n.text.include?("Please note") }

  big = doc.at_css(".mw-parser-output big big big") || doc.at_css("big big big")
  designation = big ? big.text.strip : nil

  parser_output = doc.css(".mw-parser-output").first || doc
  paragraphs = parser_output.css("p, ul, ol").reject do |el|
    el.inner_html.include?("editsection") ||
      el.text.strip.empty? ||
      el.text.strip.match?(/\A\d+-\d+-\d+\z/) ||
      (big && el.text.strip == designation)
  end

  definition_paragraphs = []
  sources = []
  paragraphs.each do |el|
    text = el.text.strip
    # Explicit prefix citation
    if (m = text.sub(CITATION_PREFIX_RE, "")) && m != text
      sources << { ref_text: m.strip, modified: !!(m =~ MODIFIED_RE) }
      next
    end
    # Bare attribution line (e.g. "C.I.E. (Auszug)" at end of body)
    if (m = text.match(BARE_CITATION_RE))
      sources << { ref_text: m[1].strip, modified: !!(m[1] =~ MODIFIED_RE) }
      next
    end
    definition_paragraphs << text
  end

  body = definition_paragraphs.reject(&:empty?).join("\n\n")
  [designation, body, sources]
end

def build_localized_doc(termid, designation, definition_body, citation_sources, page_url)
  # Citation sources extracted from the German body — typed via glossarist.
  sources = [
    Glossarist::ConceptSource.new(
      type: "authoritative",
      origin: Glossarist::Citation.new(
        ref: Glossarist::Citation::Ref.new(source: "IALA Dictionary")
      )
    ).to_hash
  ]

  citation_sources.each do |cs|
    src = Glossarist::ConceptSource.new(
      type: "authoritative",
      origin: Glossarist::Citation.new(
        ref: Glossarist::Citation::Ref.new(source: cs[:ref_text])
      )
    ).to_hash
    src["modification"] = "modified from source" if cs[:modified]
    sources << src
  end

  data = {
    "language_code" => "deu",
    "terms" => [{
      "type" => "expression",
      "designation" => designation || termid,
      "normative_status" => "preferred"
    }],
    "definition" => [{ "content" => definition_body }],
    "sources" => sources,
    "annotations" => [{ "content" => "Sourced from #{page_url}" }]
  }

  {
    "id" => "#{termid}-deu",
    "termid" => termid,
    "data" => data
  }
end

def append_localized_doc(yaml_path, localized_doc, lang)
  docs = YAML.load_stream(File.read(yaml_path))
  docs = docs.reject { |d| d && d["id"] == localized_doc["id"] }
  docs << localized_doc
  content = docs.map { |d| YAML.dump(d) }.join
  File.write(yaml_path, content)
  :appended
end

def find_concept_files(numeric_code)
  hits = []
  DATASETS.each do |edition|
    path = "datasets/#{edition}/concepts/#{numeric_code}.yaml"
    hits << path if File.exist?(path)
  end
  hits
end

index_path = "#{TRANSLATIONS_DIR}/index.json"
abort "Index not found: #{index_path}" unless File.exist?(index_path)

index = JSON.parse(File.read(index_path))
stats = { scanned: 0, skipped: 0, no_code: 0, no_target: 0, appended: 0, errors: 0 }

index.each do |entry|
  stats[:scanned] += 1
  page_file = entry["page_file"]
  full_title = entry["title"]
  english_title = entry["english_title"]

  if SKIP_TITLES.any? { |t| english_title == t }
    stats[:skipped] += 1
    next
  end

  cached_path = "reference-docs/scraped/translations/#{page_file}"
  unless File.exist?(cached_path)
    warn "  missing cache: #{cached_path}"
    stats[:no_target] += 1
    next
  end

  cached = JSON.parse(File.read(cached_path))
  wikitext = cached["wikitext"]
  numeric_code = extract_numeric_code(wikitext)

  unless numeric_code
    warn "  no numeric code in #{full_title}"
    stats[:no_code] += 1
    next
  end

  targets = find_concept_files(numeric_code)
  if targets.empty?
    warn "  no target concept #{numeric_code} for #{full_title}"
    stats[:no_target] += 1
    next
  end

  html = cached.dig("parse", "text") || ""
  designation, definition_body, citation_sources = extract_german_terms(html)
  page_url = "https://www.iala.int/wiki/dictionary/index.php/#{full_title.tr(' ', '_')}"

  targets.each do |yaml_path|
    localized = build_localized_doc(numeric_code, designation, definition_body, citation_sources, page_url)
    result = append_localized_doc(yaml_path, localized, "deu")
    stats[:appended] += 1 if result == :appended
  rescue => e
    warn "  ERROR appending to #{yaml_path}: #{e.message}"
    stats[:errors] += 1
  end
end

puts "Injected German translations:"
stats.each { |k, v| puts "  #{k}: #{v}" }