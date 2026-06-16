#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "iala_api"
require "nokogiri"
require "json"
require "fileutils"

CATEGORY = ARGV[0] || raise("Usage: ruby scrape_edition.rb <category_name>\n  e.g. ruby scrape_edition.rb \"IALA_Dictionary_1970-89_Edition\"")

EDITION_MAP = {
  "IALA_Dictionary_1970-89_Edition" => "iala-1970-89",
  "IALA_Dictionary_2023_Revision"   => "iala-2023"
}.freeze

EDITION_ID  = EDITION_MAP[CATEGORY] || CATEGORY.downcase.gsub(/[^a-z0-9-]/, "-").gsub(/-+/, "-").gsub(/^-|-$/, "")
OUTPUT_DIR  = File.join(File.dirname(__FILE__), "..", "reference-docs", "editions", EDITION_ID)
PAGES_DIR   = File.join(OUTPUT_DIR, "pages")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def title_to_slug(title)
  title.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/^-|-$/, "")
end

# Extract IALA numeric code (e.g. "4-4-400") from wikitext first, then HTML.
def extract_numeric_code(wikitext, html = nil)
  if wikitext
    m = wikitext.match(/'''(\d+-\d+-\d+)'''/)
    return m[1] if m
  end

  if html
    doc = Nokogiri::HTML(html)
    doc.css("b").each do |b|
      text = b.text.strip
      return text if text.match?(/\A\d+-\d+-\d+\z/)
    end
  end

  nil
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

FileUtils.mkdir_p(PAGES_DIR)

puts "Edition  : #{EDITION_ID}"
puts "Category : #{CATEGORY}"
puts "Output   : #{OUTPUT_DIR}"
puts

# Step 1 — list all category members
puts "Fetching category members for #{CATEGORY}..."
all_members = IalaApi.get_category_members(CATEGORY)
main_pages  = all_members.select { |m| m["ns"] == 0 }
puts "Found #{all_members.size} members total, #{main_pages.size} in main namespace (ns=0)"
puts

index = []
errors = []

main_pages.each_with_index do |member, idx|
  title = member["title"]
  slug  = title_to_slug(title)
  page_file = File.join(PAGES_DIR, "#{slug}.json")

  print "Fetching [#{idx + 1}/#{main_pages.size}]: #{title}"

  # ------------------------------------------------------------------
  # Incremental: skip if already cached
  # ------------------------------------------------------------------
  if File.exist?(page_file) && File.size(page_file) > 0
    print " (cached)\n"

    begin
      cached = JSON.parse(File.read(page_file))
      wikitext = cached["wikitext"]
      html     = cached.dig("parse", "text")
      categories = (cached.dig("parse", "categories") || []).map { |c| c["*"]&.gsub("_", " ") }.compact
      langlinks  = (cached.dig("parse", "langlinks") || []).map { |l| l["lang"] }.compact
      numeric_code = extract_numeric_code(wikitext, html)

      index << {
        "title"        => title,
        "numeric_code" => numeric_code,
        "categories"   => categories,
        "lang_variants" => langlinks,
        "page_file"    => "pages/#{slug}.json"
      }
    rescue => e
      $stderr.puts "\n  WARN: Could not read cached file #{page_file}: #{e.message}"
      errors << { title: title, error: e.message }
    end

    next
  end

  print "\n"

  begin
    # Fetch parsed HTML + metadata
    parse_result = IalaApi.parse_page(title)
    html         = parse_result[:text]
    categories   = (parse_result[:categories] || []).map { |c| c["*"]&.gsub("_", " ") }.compact
    langlinks    = parse_result[:langlinks] || []
    lang_codes   = langlinks.map { |l| l["lang"] }.compact

    # Fetch raw wikitext
    wikitext = IalaApi.get_page_content(title)

    # Extract numeric code
    numeric_code = extract_numeric_code(wikitext, html)

    # Build page document
    page_doc = {
      "title"    => title,
      "parse"    => {
        "text"       => html,
        "categories" => parse_result[:categories],
        "langlinks"  => langlinks
      },
      "wikitext" => wikitext
    }

    # Save page JSON
    File.write(page_file, JSON.pretty_generate(page_doc), encoding: "utf-8")

    # Optionally fetch lang variant pages (best-effort)
    langlinks.each do |ll|
      lang      = ll["lang"]
      lang_title = ll["*"] || ll["title"]
      next unless lang_title && !lang_title.empty?

      lang_slug      = "#{slug}.#{lang}"
      lang_page_file = File.join(PAGES_DIR, "#{lang_slug}.json")

      next if File.exist?(lang_page_file) && File.size(lang_page_file) > 0

      begin
        puts "  → Fetching lang variant [#{lang}]: #{lang_title}"
        lang_parse   = IalaApi.parse_page(lang_title)
        lang_wikitext = IalaApi.get_page_content(lang_title)

        lang_doc = {
          "title"    => lang_title,
          "lang"     => lang,
          "parse"    => {
            "text"       => lang_parse[:text],
            "categories" => lang_parse[:categories],
            "langlinks"  => lang_parse[:langlinks]
          },
          "wikitext" => lang_wikitext
        }

        File.write(lang_page_file, JSON.pretty_generate(lang_doc), encoding: "utf-8")
      rescue => e
        $stderr.puts "  WARN: Failed to fetch lang variant [#{lang}] #{lang_title}: #{e.message}"
      end
    end

    index << {
      "title"         => title,
      "numeric_code"  => numeric_code,
      "categories"    => categories,
      "lang_variants" => lang_codes,
      "page_file"     => "pages/#{slug}.json"
    }

  rescue => e
    $stderr.puts "  ERROR: Failed to fetch #{title}: #{e.message}"
    errors << { title: title, error: e.message }
  end
end

puts
puts "Scraped #{index.size} pages (#{errors.size} errors)"

# ---------------------------------------------------------------------------
# Save index.json
# ---------------------------------------------------------------------------
index_file = File.join(OUTPUT_DIR, "index.json")
File.write(index_file, JSON.pretty_generate(index), encoding: "utf-8")
puts "Index saved to: #{index_file}"

unless errors.empty?
  puts "\nErrors (#{errors.size}):"
  errors.each { |e| puts "  - #{e[:title]}: #{e[:error]}" }
end

puts "\nDone."
