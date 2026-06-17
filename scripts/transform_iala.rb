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

# Regexes for IALA wiki paragraph classification. Leading <br>/whitespace
# tolerated because the wiki often precedes Note:/Reference: with a <br>.
NOTE_RE = /\A\s*(?:<br\s*\/?>[\s\n]*)*Note:\s*/i
REFERENCE_RE = /\A\s*(?:<br\s*\/?>[\s\n]*)*Reference:\s*/i
ALT_TERM_RE = /\A\s*(?:<br\s*\/?>[\s\n]*)*Alternative\s+term:\s*/i
MODIFIED_RE = /\(modified\)/i
# "term 1-1-030" or "terms 1-1-030, 1-1-040" patterns used in cross-refs
TERMID_MENTION_RE = /\bterm(?:s)?\s+(\d+-\d+-\d+(?:\s*,\s*\d+-\d+-\d+)*)\b/i
TERMID_ONLY_RE = /\A(\d+-\d+-\d+)\z/

# Pre-scan: build termid → designation index from the edition's index.json.
# Used to convert "term 1-1-030" mentions into {1-1-030, Coast guard station}
# inline-ref syntax that concept-browser auto-resolves into hyperlinks.
designation_index = {}
index.each do |it|
  code = it["numeric_code"]
  title = it["title"]
  next if code.nil? || code.empty? || title.nil?
  designation_index[code] = title
end

# Load translations cache (produced by scrape_translations.rb). IALA wiki
# doesn't use MediaWiki interlanguage links — French (`/fr`) and Spanish
# (`/es`) variants live at separate URLs, indexed by their own categories.
# Map: english_title → { "fra" => page_data, "spa" => page_data }.
translations = Hash.new { |h, k| h[k] = {} }
{
  "fra" => "reference-docs/translations/fra/index.json",
  "spa" => "reference-docs/translations/spa/index.json",
}.each do |lang, path|
  next unless File.exist?(path)
  entries = JSON.parse(File.read(path))
  entries.each do |e|
    en_title = e["english_title"]
    page_rel = e["page_file"]
    next if en_title.nil? || en_title.empty? || page_rel.nil?
    # page_file is like "fra/audible-signal-fr.json"; resolve relative to translations dir
    page_path = File.join("reference-docs/translations", page_rel)
    translations[en_title][lang] = page_path if File.exist?(page_path)
  end
end
puts "Loaded translations: #{translations.count { |_, v| v.key?('fra') }} fr, #{translations.count { |_, v| v.key?('spa') }} es"

# Collect bibliographic references across all concepts; written at end.
bibliography = {}

# Inject {{termid, designation}} inline-ref syntax for any "term X-Y-Z" mention.
# concept-browser's extractInlineRefs dispatches {{...}} mentions by parseMention
# kind; numeric kind → handleNumeric → resolves to same-dataset concept URI.
# (Single-brace {...} requires refPrefixMap config we don't have.)
def inject_termid_refs(text, designation_index)
  text.gsub(TERMID_MENTION_RE) do |match|
    ids_string = $1
    prefix = match =~ /^terms/i ? "terms " : "term "
    ids = ids_string.split(/,\s*/).map(&:strip)
    prefix + ids.map do |id|
      designation = designation_index[id]
      designation ? "{{#{id}, #{designation}}}" : id
    end.join(", ")
  end
end

# Classify a paragraph element as :definition, :note, :reference, :symbol,
# :unit, or :alt_term based on the IALA wiki's paragraph conventions.
# IALA wiki is inconsistent: "Symbol Qe" and "Symbol: V(λ)" both appear.
# Match both forms (colon optional).
def classify_paragraph(text)
  return :note if text =~ NOTE_RE || text =~ /\A\s*(?:<br\s*\/?>[\s\n]*)*Note(?:\s*\d+)?\s*:?\s/i
  return :reference if text =~ REFERENCE_RE
  return :symbol if text =~ /\A\s*Symbol\s*:?\s+/i
  return :unit if text =~ /\A\s*Unit\s*:?\s+/i
  return :alt_term if text =~ ALT_TERM_RE
  :definition
end

# Normalize a bibliographic reference: collapse whitespace, strip "(modified)"
# marker (returned separately), and strip trailing dots.
def normalize_ref(text)
  cleaned = text.gsub(/\s+/, ' ').strip
  modified = !!(cleaned =~ MODIFIED_RE)
  cleaned = cleaned.sub(/\(modified\)/i, '').strip
  cleaned = cleaned.sub(/\.{1,}\s*\z/, '').strip
  [cleaned, modified]
end

# Convert a Nokogiri element's HTML to text, preserving <img> as markdown
# image refs pointing at our downloaded copies in public/images/iala/.
# Without this, el.text strips <img> entirely and figures go missing.
def element_to_text(el)
  html = el.inner_html
  html = html.gsub(/<img[^>]+src="([^"]+)"[^>]*>/i) do
    src = $1
    basename = src.split('/').last.sub(/\?.*$/, '').sub(/\A\d+px-/, '')
    "![#{basename}](/iala-vocab/images/iala/#{basename})"
  end
  html = html.gsub(/<br\s*\/?>/i, "\n")
  txt = Nokogiri::HTML(html).text
  txt.split("\n").map(&:strip).reject(&:empty?).join("\n").strip
end

# Split paragraphs on inline structural markers — but only when the paragraph
# doesn't itself start with a marker. A paragraph that starts with "Note:" is
# kept whole even if "Reference:" appears mid-text inside it (that mid-text
# Reference is descriptive, not a structural citation).
STRUCTURAL_MARKER_RE = /(?=\s(?:Symbol|Unit|Note(?:\s*\d+)?|Reference|Alternative\s+term)\s*:\s)/i
PARAGRAPH_HEAD_MARKER_RE = /\A\s*(?:<br\s*\/?>[\s\n]*)*(Note(?:\s*\d+)?|Reference|Symbol|Unit|Alternative\s+term)\s*:/i

def split_to_fragments(elements)
  fragments = []
  elements.each do |el|
    txt = element_to_text(el)
    next if txt.empty?
    if txt =~ PARAGRAPH_HEAD_MARKER_RE
      fragments << txt
    else
      sub = txt.split(STRUCTURAL_MARKER_RE).map(&:strip).reject(&:empty?)
      fragments.concat(sub)
    end
  end
  fragments
end

# Strip a leading "N " or "N. " source-list number from note text.
def strip_note_leading_number(text)
  text.sub(/\A\s*\d+\s*(?:\.\s*)?/, '')
end

# Convert parenthetical "(X-Y-Z)" mentions into {{termid, designation}} so
# concept-browser's extractInlineRefs can resolve them as cross-concept links.
def inject_paren_termid_refs(text, designation_index)
  text.gsub(/\((\d+-\d+-\d+)\)/) do
    id = $1
    designation = designation_index[id]
    designation ? "{{#{id}, #{designation}}}" : "(#{id})"
  end
end

# Apply both cross-ref injections in one pass.
def inject_all_refs(text, designation_index)
  inject_paren_termid_refs(inject_termid_refs(text, designation_index), designation_index)
end

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
  
  # The "Please note that this is the term as it stands in the original IALA
  # Dictionary edition" disclaimer is intentionally NOT extracted: the same
  # provenance information is already encoded via the cross-edition
  # `related: type: equivalent` link injected by link_editions.rb.
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

  # Drop IALA wiki placeholders that pollute definitions. Note: image-only
  # paragraphs have empty .text but contain <img> — keep those so figures
  # survive (element_to_text converts <img> to markdown image refs).
  content_elements = content_elements.reject do |el|
    txt = el.text.strip
    has_img = !el.css('img').empty?
    (txt.empty? && !has_img) ||
      txt =~ /\A\s*No\s+English\s+term\s*\z/i ||
      (numeric_code && !numeric_code.empty? && txt == numeric_code)
  end

  # Split paragraphs on inline structural markers so each Symbol:/Unit:/Note:/
  # Reference:/Alternative-term: becomes its own fragment for classification.
  fragments = split_to_fragments(content_elements)

  definition_paragraphs = []
  extracted_notes = [] # only "Note N:" paragraphs from source — count must match
  extracted_refs = [] # Array of [ref_text, modified_bool]
  extracted_symbols = [] # terms[] entries with type:symbol
  annotations = [] # anything we add beyond source: Unit blocks, provenance URL
  alt_terms = []
  modified_any = false
  last_annotation_kind = nil
  fragments.each do |frag|
    case classify_paragraph(frag)
    when :note
      note_text = frag.sub(/\A\s*(?:<br\s*\/?>[\s\n]*)*Note(?:\s*\d+)?\s*:?\s/i, '').strip
      note_text = strip_note_leading_number(note_text)
      note_text = inject_all_refs(note_text, designation_index)
      extracted_notes << { "content" => note_text }
      last_annotation_kind = nil
    when :reference
      ref_text = frag.sub(/\A\s*(?:<br\s*\/?>[\s\n]*)*Reference:\s*/i, '')
      ref, mod = normalize_ref(ref_text)
      modified_any ||= mod
      extracted_refs << [ref, mod]
      last_annotation_kind = nil
    when :symbol
      # "Symbol Qe" or "Symbol: V(λ)" → math notation stem:[X] for KaTeX rendering.
      # If extra formula text follows the symbol on the same line (e.g.
      # "Symbol He He = ?Ee.dt"), the trailing formula stays in definition.
      rest = frag.sub(/\A\s*Symbol\s*:?\s+/i, '')
      parts = rest.split(/\s+/, 2)
      extracted_symbols << "stem:[#{parts[0]}]" if parts[0] && !parts[0].empty?
      definition_paragraphs << parts[1] if parts[1] && !parts[1].empty?
      last_annotation_kind = nil
    when :unit
      # "Unit X" + any immediately-following conversion lines (e.g. "1 J = ...")
      # group into a single annotation. Internal newlines preserved.
      unit_text = frag.sub(/\A\s*Unit\s*:?\s+/i, '')
      annotations << { "content" => "Unit #{unit_text}" }
      last_annotation_kind = :unit
    when :alt_term
      alt_terms << frag.sub(ALT_TERM_RE, '').strip
      last_annotation_kind = nil
    else
      # Conversion lines following a Unit paragraph attach to the previous
      # Unit annotation rather than becoming standalone definition paragraphs.
      if last_annotation_kind == :unit && frag =~ /\A\s*\d+\s*[A-Za-z]+\s*=/
        annotations.last["content"] += "\n#{frag.strip}"
      elsif frag =~ /\A\s*#{Regexp.escape(designation)}\s*\([^)]+\)\s*\z/i
        # IALA wiki convention: an early paragraph containing "Title (qualifier)"
        # is an admitted expanded designation, not a definition sentence.
        alt_terms << frag.strip
        last_annotation_kind = nil
      else
        definition_paragraphs << frag
        last_annotation_kind = nil
      end
    end
  end

  if definition_paragraphs.any? { |p| p =~ MODIFIED_RE }
    modified_any = true
    definition_paragraphs = definition_paragraphs.map { |p| p.sub(/\s*\(modified\)\s*/i, '').strip }
  end

  # Numbered definitions (1./2./3.) → separate definition[] entries (homonym senses).
  # Non-numbered multi-paragraph bodies → ONE definition[] entry preserving newlines.
  numbered = definition_paragraphs.all? { |p| p =~ /\A\s*\d+\.\s+/ }
  if numbered && definition_paragraphs.size > 1
    definition_entries = definition_paragraphs.map do |p|
      inject_all_refs(p.sub(/\A\s*\d+\.\s+/, '').strip, designation_index)
    end.reject(&:empty?)
  else
    joined = definition_paragraphs.map { |p| inject_all_refs(p, designation_index) }.reject(&:empty?).join("\n\n")
    definition_entries = joined.empty? ? [] : [joined]
  end
  definition_entries = [title] if definition_entries.empty?

  extracted_refs.each do |ref, _|
    slug = sanitize(ref)
    bibliography[slug] ||= { "reference" => ref }
  end
  
  # Build YAML documents
  docs = []

  # Doc 1: Managed Concept (Glossarist v3 — wrap identifier/domains in data:)
  mc = {
    "id" => termid,
    "data" => {
      "identifier" => termid,
      "domains" => [
        {
          "source" => "urn:iala:dictionary:#{edition}",
          "concept_id" => "section-#{section_id}",
          "ref_type" => "section"
        }
      ]
    },
    "status" => "valid",
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

  # Doc 2: English Localized Concept (Glossarist v3 — language_code in data:)
  eng_lang = "eng"
  if title.end_with?("/es")
    eng_lang = "spa"
  elsif title.end_with?("/fre")
    eng_lang = "fra"
  end

  # Terms: preferred designation from title; admitted from "Alternative term:"
  # paragraphs; symbol designations from "Symbol:" markers (Glossarist v3
  # supports type: symbol alongside expression/abbreviation).
  terms = [
    {
      "type" => "expression",
      "designation" => designation,
      "normative_status" => "preferred"
    }
  ]
  alt_terms.each do |alt|
    terms << {
      "type" => "expression",
      "designation" => alt,
      "normative_status" => "admitted"
    }
  end
  extracted_symbols.each do |sym|
    terms << {
      "type" => "symbol",
      "designation" => sym,
      "normative_status" => "preferred"
    }
  end

  # Sources: IALA Dictionary authoritative + any "Reference: X" bibliographic.
  lc_sources = [
    {
      "type" => "authoritative",
      "origin" => { "ref" => "IALA Dictionary" }
    }
  ]
  extracted_refs.each do |ref, ref_mod|
    src = { "type" => "authoritative", "origin" => { "ref" => ref } }
    src["modification"] = "modified from source" if ref_mod || modified_any
    lc_sources << src
  end

  # Annotations: Unit blocks + provenance URL pointing at the upstream IALA
  # wiki page this concept was scraped from. Anything we ADD beyond source
  # goes here (never to notes — notes count must match source).
  source_url = "https://www.iala.int/wiki/dictionary/index.php/#{title.gsub(' ', '_')}"
  all_annotations = annotations + [{ "content" => "Sourced from #{source_url}" }]

  lc_en = {
    "id" => "#{termid}-#{eng_lang}",
    "termid" => termid,
    "data" => {
      "language_code" => eng_lang
    },
    "terms" => terms,
    "definition" => definition_entries.map { |e| { "content" => e } },
    "sources" => lc_sources
  }
  lc_en["notes"] = extracted_notes unless extracted_notes.empty?
  lc_en["annotations"] = all_annotations unless all_annotations.empty?
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
    
    ll_doc.css("i").each { |i| i.remove if i.text.include?("Please note that this is the term") }
    ll_doc.css(".LanguageLinks").remove
    ll_doc.css(".mw-lingo-tooltip").remove
    ll_doc.css("#toc").remove

    ll_parser_output = ll_doc.css(".mw-parser-output").first || ll_doc
    ll_content_elements = ll_doc.css(".mw-parser-output p, .mw-parser-output ul, .mw-parser-output ol").reject do |el|
      el.ancestors.any? { |a| %w[catlinks LanguageLinks mw-lingo-tooltip].any? { |c| a["class"].to_s.include?(c) } } ||
      el.inner_html.include?("editsection")
    end

    # Mirror English-page fragment classification (placeholders, structural
    # marker split, Symbol/Unit extraction, numbered-definition handling).
    ll_fragments = split_to_fragments(ll_content_elements)
    ll_definition_paragraphs = []
    ll_extracted_notes = []
    ll_extracted_refs = []
    ll_extracted_symbols = []
    ll_annotations = []
    ll_alt_terms = []
    ll_modified_any = false
    ll_last_annotation_kind = nil
    ll_fragments.each do |frag|
      next if frag.empty? || frag =~ /\A\s*No\s+English\s+term\s*\z/i ||
              (numeric_code && !numeric_code.empty? && frag == numeric_code)
      case classify_paragraph(frag)
      when :note
        note_text = frag.sub(/\A\s*(?:<br\s*\/?>[\s\n]*)*Note(?:\s*\d+)?\s*:?\s/i, '').strip
        note_text = strip_note_leading_number(note_text)
        note_text = inject_all_refs(note_text, designation_index)
        ll_extracted_notes << { "content" => note_text }
        ll_last_annotation_kind = nil
      when :reference
        ref_text = frag.sub(/\A\s*(?:<br\s*\/?>[\s\n]*)*Reference:\s*/i, '')
        ref, mod = normalize_ref(ref_text)
        ll_modified_any ||= mod
        ll_extracted_refs << [ref, mod]
        ll_last_annotation_kind = nil
      when :symbol
        rest = frag.sub(/\A\s*Symbol\s*:?\s+/i, '')
        parts = rest.split(/\s+/, 2)
        ll_extracted_symbols << "stem:[#{parts[0]}]" if parts[0] && !parts[0].empty?
        ll_definition_paragraphs << parts[1] if parts[1] && !parts[1].empty?
        ll_last_annotation_kind = nil
      when :unit
        unit_text = frag.sub(/\A\s*Unit\s*:?\s+/i, '')
        ll_annotations << { "content" => "Unit #{unit_text}" }
        ll_last_annotation_kind = :unit
      when :alt_term
        ll_alt_terms << frag.sub(ALT_TERM_RE, '').strip
        ll_last_annotation_kind = nil
      else
        if ll_last_annotation_kind == :unit && frag =~ /\A\s*\d+\s*[A-Za-z]+\s*=/
          ll_annotations.last["content"] += "\n#{frag.strip}"
        elsif frag =~ /\A\s*#{Regexp.escape(ll[:title])}\s*\([^)]+\)\s*\z/i
          ll_alt_terms << frag.strip
          ll_last_annotation_kind = nil
        else
          ll_definition_paragraphs << frag
          ll_last_annotation_kind = nil
        end
      end
    end

    if ll_definition_paragraphs.any? { |p| p =~ MODIFIED_RE }
      ll_modified_any = true
      ll_definition_paragraphs = ll_definition_paragraphs.map { |p| p.sub(/\s*\(modified\)\s*/i, '').strip }
    end

    ll_numbered = ll_definition_paragraphs.size > 1 && ll_definition_paragraphs.all? { |p| p =~ /\A\s*\d+\.\s+/ }
    if ll_numbered
      ll_definition_entries = ll_definition_paragraphs.map do |p|
        inject_all_refs(p.sub(/\A\s*\d+\.\s+/, '').strip, designation_index)
      end.reject(&:empty?)
    else
      joined = ll_definition_paragraphs.map { |p| inject_all_refs(p, designation_index) }.reject(&:empty?).join("\n\n")
      ll_definition_entries = joined.empty? ? [] : [joined]
    end
    ll_definition_entries = [ll[:title]] if ll_definition_entries.empty?

    ll_extracted_refs.each do |ref, _|
      slug = sanitize(ref)
      bibliography[slug] ||= { "reference" => ref }
    end

    ll_terms = [
      {
        "type" => "expression",
        "designation" => ll[:title],
        "normative_status" => "preferred"
      }
    ]
    ll_alt_terms.each do |alt|
      ll_terms << {
        "type" => "expression",
        "designation" => alt,
        "normative_status" => "admitted"
      }
    end
    ll_extracted_symbols.each do |sym|
      ll_terms << {
        "type" => "symbol",
        "designation" => sym,
        "normative_status" => "preferred"
      }
    end

    ll_sources = [
      { "type" => "authoritative", "origin" => { "ref" => "IALA Dictionary" } }
    ]
    ll_extracted_refs.each do |ref, ref_mod|
      src = { "type" => "authoritative", "origin" => { "ref" => ref } }
      src["modification"] = "modified from source" if ref_mod || ll_modified_any
      ll_sources << src
    end

    ll_source_url = "https://www.iala.int/wiki/dictionary/index.php/#{ll[:title].gsub(' ', '_')}"
    ll_all_annotations = ll_annotations + [{ "content" => "Sourced from #{ll_source_url}" }]

    lc_ll = {
      "id" => "#{termid}-#{ll[:lang]}",
      "termid" => termid,
      "data" => {
        "language_code" => ll[:lang]
      },
      "terms" => ll_terms,
      "definition" => ll_definition_entries.map { |e| { "content" => e } },
      "sources" => ll_sources
    }
    lc_ll["notes"] = ll_extracted_notes unless ll_extracted_notes.empty?
    lc_ll["annotations"] = ll_all_annotations unless ll_all_annotations.empty?
    docs << lc_ll

    # Mark as processed so we don't duplicate it later when iterating index.json
    processed_pages[ll[:title]] = true
  end

  # Inject translations from the standalone /fr and /es caches. IALA wiki
  # stores these at separate URLs (e.g. /wiki/Audible_Signal/fr) and indexes
  # them in their own categories, not via interlanguage links on the English
  # page. Match by English title.
  if translations.key?(title)
    translations[title].each do |lang, page_path|
      tr_page = JSON.parse(File.read(page_path))
      tr_html = tr_page.dig("parse", "text") || ""
      tr_doc = Nokogiri::HTML(tr_html)
      tr_doc.css("i").each { |i| i.remove if i.text.include?("Please note that this is the term") }
      tr_doc.css(".LanguageLinks").remove
      tr_doc.css(".mw-lingo-tooltip").remove
      tr_doc.css("#toc").remove

      tr_elements = tr_doc.css(".mw-parser-output p, .mw-parser-output ul, .mw-parser-output ol").reject do |el|
        el.ancestors.any? { |a| %w[catlinks LanguageLinks mw-lingo-tooltip].any? { |c| a["class"].to_s.include?(c) } } ||
        el.inner_html.include?("editsection")
      end
      tr_fragments = split_to_fragments(tr_elements)

      tr_definition_paragraphs = []
      tr_extracted_notes = []
      tr_extracted_refs = []
      tr_extracted_symbols = []
      tr_annotations = []
      tr_alt_terms = []
      tr_modified_any = false
      tr_last_kind = nil
      tr_designation = title
      tr_fragments.each do |frag|
        next if frag.empty? || frag =~ /\A\s*No\s+English\s+term\s*\z/i
        case classify_paragraph(frag)
        when :note
          note_text = frag.sub(/\A\s*(?:<br\s*\/?>[\s\n]*)*Note(?:\s*\d+)?\s*:?\s/i, '').strip
          note_text = strip_note_leading_number(note_text)
          note_text = inject_all_refs(note_text, designation_index)
          tr_extracted_notes << { "content" => note_text }
          tr_last_kind = nil
        when :reference
          ref_text = frag.sub(/\A\s*(?:<br\s*\/?>[\s\n]*)*Reference:\s*/i, '')
          ref, mod = normalize_ref(ref_text)
          tr_modified_any ||= mod
          tr_extracted_refs << [ref, mod]
          tr_last_kind = nil
        when :symbol
          rest = frag.sub(/\A\s*Symbol\s*:?\s+/i, '')
          parts = rest.split(/\s+/, 2)
          tr_extracted_symbols << "stem:[#{parts[0]}]" if parts[0] && !parts[0].empty?
          tr_definition_paragraphs << parts[1] if parts[1] && !parts[1].empty?
          tr_last_kind = nil
        when :unit
          tr_annotations << { "content" => "Unit #{frag.sub(/\A\s*Unit\s*:?\s+/i, '')}" }
          tr_last_kind = :unit
        when :alt_term
          tr_alt_terms << frag.sub(ALT_TERM_RE, '').strip
          tr_last_kind = nil
        else
          if tr_last_kind == :unit && frag =~ /\A\s*\d+\s*[A-Za-z]+\s*=/
            tr_annotations.last["content"] += "\n#{frag.strip}"
          else
            tr_definition_paragraphs << frag
            tr_last_kind = nil
          end
        end
      end

      # First non-empty definition paragraph is typically the localized
      # designation; the rest form the definition body.
      if tr_definition_paragraphs.any? && tr_designation == title
        first = tr_definition_paragraphs.first.strip
        # Heuristic: short first paragraph (≤ 60 chars, no terminal period)
        # is the localized term, not part of the definition.
        if first.length <= 60 && !first.end_with?('.')
          tr_designation = first
          tr_definition_paragraphs.shift
        end
      end

      if tr_definition_paragraphs.any? { |p| p =~ MODIFIED_RE }
        tr_modified_any = true
        tr_definition_paragraphs = tr_definition_paragraphs.map { |p| p.sub(/\s*\(modified\)\s*/i, '').strip }
      end

      tr_numbered = tr_definition_paragraphs.size > 1 && tr_definition_paragraphs.all? { |p| p =~ /\A\s*\d+\.\s+/ }
      if tr_numbered
        tr_definition_entries = tr_definition_paragraphs.map do |p|
          inject_all_refs(p.sub(/\A\s*\d+\.\s+/, '').strip, designation_index)
        end.reject(&:empty?)
      else
        joined = tr_definition_paragraphs.map { |p| inject_all_refs(p, designation_index) }.reject(&:empty?).join("\n\n")
        tr_definition_entries = joined.empty? ? [] : [joined]
      end

      tr_terms = [{
        "type" => "expression",
        "designation" => tr_designation,
        "normative_status" => "preferred"
      }]
      tr_alt_terms.each do |alt|
        tr_terms << { "type" => "expression", "designation" => alt, "normative_status" => "admitted" }
      end
      tr_extracted_symbols.each do |sym|
        tr_terms << { "type" => "symbol", "designation" => sym, "normative_status" => "preferred" }
      end

      tr_sources = [{ "type" => "authoritative", "origin" => { "ref" => "IALA Dictionary" } }]
      tr_extracted_refs.each do |ref, ref_mod|
        src = { "type" => "authoritative", "origin" => { "ref" => ref } }
        src["modification"] = "modified from source" if ref_mod || tr_modified_any
        tr_sources << src
        slug = sanitize(ref)
        bibliography[slug] ||= { "reference" => ref }
      end

      tr_source_url = "https://www.iala.int/wiki/dictionary/index.php/#{title.gsub(' ', '_')}/#{lang == 'fra' ? 'fr' : 'es'}"
      tr_annotations << { "content" => "Sourced from #{tr_source_url}" }

      lc_tr = {
        "id" => "#{termid}-#{lang}",
        "termid" => termid,
        "data" => { "language_code" => lang },
        "terms" => tr_terms,
        "definition" => tr_definition_entries.map { |e| { "content" => e } },
        "sources" => tr_sources
      }
      lc_tr["notes"] = tr_extracted_notes unless tr_extracted_notes.empty?
      lc_tr["annotations"] = tr_annotations unless tr_annotations.empty?
      docs << lc_tr
    end
  end
  
  # Write YAML
  File.open("#{out_dir}/#{termid}.yaml", "w") do |f|
    docs.each do |d|
      f.puts "---"
      f.puts d.to_yaml.sub(/\A---\n/, "")
    end
  end
end

# Write bibliography.yaml: one entry per distinct "Reference: X" found across
# the edition's concepts. Keyed by slug; concepts cite via the human-readable
# ref text in their sources[].origin.ref — matches oiml-vocab's bibliography
# pattern consumed by concept-browser (generate-data.mjs copies it verbatim
# to public/data/{edition}/bibliography.json).
bib_path = "datasets/#{edition}/bibliography.yaml"
File.open(bib_path, "w") do |f|
  f.puts "---"
  f.puts "# Bibliography of external references cited by #{edition} concepts."
  f.puts "# Auto-extracted from 'Reference: ...' paragraphs on IALA wiki pages."
  bibliography.each do |slug, entry|
    f.puts "#{slug}:"
    entry.each do |k, v|
      f.puts "  #{k}: #{v.to_json}"
    end
  end
end

puts "Processed #{seen_termids.size} concepts for #{edition}"
puts "Wrote bibliography (#{bibliography.size} entries) to #{bib_path}"
