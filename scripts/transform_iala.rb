#!/usr/bin/env ruby
require 'json'
require 'nokogiri'
require 'yaml'
require 'fileutils'

edition = ARGV[0]
unless edition
  puts "Usage: bundle exec ruby scripts/transform_iala.rb <edition_id>"
  exit 1
end

index_path = "reference-docs/editions/#{edition}/index.json"
unless File.exist?(index_path)
  puts "Index not found: #{index_path}"
  exit 1
end

index = JSON.parse(File.read(index_path))
out_dir = "datasets/#{edition}/concepts"
FileUtils.mkdir_p(out_dir)

def sanitize(str)
  str.downcase.gsub(/[^a-z0-9]+/, '-')
end

# Keep track of termids to handle suffixes
seen_termids = Hash.new(0)
processed_pages = {}

# Map lang names to ISO 639-2 codes
LANG_MAP = {
  "español" => "spa",
  "français" => "fra",
  "deutsch" => "deu"
}

index.each do |item|
  title = item["title"]
  next if processed_pages[title]
  
  page_file = item["page_file"]
  
  # If this page was already processed as a langlink, we can skip it, OR
  # we can just process it. But to avoid garbage concepts, let's process it
  # unless we explicitly decide to skip. The instructions say "For each concept..."
  # We will just process everything.
  
  # But let's try to grab langlinks when processing a main page.
  
  cached_path = "reference-docs/editions/#{edition}/#{page_file}"
  next unless File.exist?(cached_path)
  
  page = JSON.parse(File.read(cached_path))
  html = page.dig("parse", "text") || ""
  doc = Nokogiri::HTML(html)
  
  # Extract fields
  numeric_code = item["numeric_code"]
  termid_base = (numeric_code && !numeric_code.empty?) ? numeric_code : sanitize(title)
  
  # Append suffix if needed
  seen_termids[termid_base] += 1
  suffix = seen_termids[termid_base] > 1 ? "-#{seen_termids[termid_base] - 1}" : ""
  termid = "#{termid_base}#{suffix}"
  
  designation = title
  
  # Domains
  section_id = nil
  (item["categories"] || []).each do |cat|
    if cat =~ /^(\d+)\.\d+/
      section_id = $1
      break
    end
  end
  section_id ||= "unknown"
  
  # Notes
  notes = []
  doc.css("i").each do |i_tag|
    text = i_tag.text.strip
    notes << text if text.include?("Please note that this is the term")
  end
  
  # Clean DOM for definition
  doc.css("i").each { |i| i.remove if i.text.include?("Please note that this is the term") }
  
  # Extract langlinks before removing them!
  langlinks = []
  doc.css(".LanguageLinks a").each do |a|
    next if a['class'] && a['class'].include?('selflink')
    target_title = a['title']
    lang_text = a.text.strip
    lang_code = LANG_MAP[lang_text] || "eng"
    next if lang_code == "eng"
    langlinks << { title: target_title, lang: lang_code }
  end
  
  doc.css(".LanguageLinks").remove
  doc.css(".mw-lingo-tooltip").remove
  doc.css("#toc").remove
  
  parser_output = doc.css(".mw-parser-output").first || doc
  content_elements = doc.css(".mw-parser-output p, .mw-parser-output ul, .mw-parser-output ol").reject do |el|
    el.ancestors.any? { |a| %w[catlinks LanguageLinks mw-lingo-tooltip].any? { |c| a["class"].to_s.include?(c) } } ||
    el.inner_html.include?("editsection")
  end
  
  definition_text = content_elements.map(&:text).join("\n\n").strip
  if numeric_code && !numeric_code.empty? && definition_text.start_with?(numeric_code)
    definition_text = definition_text.sub(numeric_code, '').strip
  end
  
  definition_text = title if definition_text.empty?
  
  # Build YAML documents
  docs = []
  
  # Doc 1: Managed Concept
  mc = {
    "id" => termid,
    "termid" => termid,
    "status" => "valid",
    "domains" => [
      {
        "source" => "urn:iala:dictionary:#{edition}",
        "concept_id" => "section-#{section_id}",
        "ref_type" => "section"
      }
    ],
    "sources" => [
      {
        "type" => "authoritative",
        "origin" => {
          "ref" => "IALA Dictionary",
          "link" => "https://www.iala.int/wiki/dictionary/index.php/#{title.gsub(' ', '_')}"
        }
      }
    ]
  }
  docs << mc
  
  # Doc 2: English Localized Concept
  # Note: The instruction specifies `eng`? It says `language_code: "{lang}"`. Let's use `eng`.
  eng_lang = "eng"
  # If the title ends with /es, it's actually Spanish, but let's just use `eng` for the main page 
  # as per "languages: English from main page."
  if title.end_with?("/es")
    eng_lang = "spa"
  elsif title.end_with?("/fre")
    eng_lang = "fra"
  end
  
  lc_en = {
    "id" => "#{termid}-#{eng_lang}",
    "termid" => termid,
    "language_code" => eng_lang,
    "terms" => [
      {
        "type" => "expression",
        "designation" => designation,
        "normative_status" => "preferred"
      }
    ],
    "definition" => [
      { "content" => definition_text }
    ],
    "sources" => [
      {
        "type" => "authoritative",
        "origin" => {
          "ref" => "IALA Dictionary"
        }
      }
    ]
  }
  lc_en["notes"] = notes unless notes.empty?
  docs << lc_en
  
  # Process langlinks
  langlinks.each do |ll|
    # Find cached page for ll[:title]
    ll_page_file = "pages/#{ll[:title].downcase.gsub(/[^a-z0-9]+/, '-')}.json"
    ll_cached_path = "reference-docs/editions/#{edition}/#{ll_page_file}"
    next unless File.exist?(ll_cached_path)
    
    ll_page = JSON.parse(File.read(ll_cached_path))
    ll_html = ll_page.dig("parse", "text") || ""
    ll_doc = Nokogiri::HTML(ll_html)
    
    ll_notes = []
    ll_doc.css("i").each do |i_tag|
      text = i_tag.text.strip
      ll_notes << text if text.include?("Please note that this is the term")
    end
    ll_doc.css("i").each { |i| i.remove if i.text.include?("Please note that this is the term") }
    ll_doc.css(".LanguageLinks").remove
    ll_doc.css(".mw-lingo-tooltip").remove
    ll_doc.css("#toc").remove
    
    ll_parser_output = ll_doc.css(".mw-parser-output").first || ll_doc
    ll_content_elements = ll_doc.css(".mw-parser-output p, .mw-parser-output ul, .mw-parser-output ol").reject do |el|
      el.ancestors.any? { |a| %w[catlinks LanguageLinks mw-lingo-tooltip].any? { |c| a["class"].to_s.include?(c) } } ||
      el.inner_html.include?("editsection")
    end
    
    ll_def = ll_content_elements.map(&:text).join("\n\n").strip
    if numeric_code && !numeric_code.empty? && ll_def.start_with?(numeric_code)
      ll_def = ll_def.sub(numeric_code, '').strip
    end
    ll_def = ll[:title] if ll_def.empty?
    
    lc_ll = {
      "id" => "#{termid}-#{ll[:lang]}",
      "termid" => termid,
      "language_code" => ll[:lang],
      "terms" => [
        {
          "type" => "expression",
          "designation" => ll[:title],
          "normative_status" => "preferred"
        }
      ],
      "definition" => [
        { "content" => ll_def }
      ],
      "sources" => [
        {
          "type" => "authoritative",
          "origin" => {
            "ref" => "IALA Dictionary"
          }
        }
      ]
    }
    lc_ll["notes"] = ll_notes unless ll_notes.empty?
    docs << lc_ll
    
    # Mark as processed so we don't duplicate it later when iterating index.json
    processed_pages[ll[:title]] = true
  end
  
  # Write YAML
  File.open("#{out_dir}/#{termid}.yaml", "w") do |f|
    docs.each do |d|
      f.puts "---"
      f.puts d.to_yaml.sub(/\A---\n/, "")
    end
  end
end

puts "Processed #{seen_termids.size} concepts for #{edition}"
