#!/usr/bin/env ruby
require_relative "iala_api"
require "json"
require "fileutils"

CATEGORY = "Historic_Terms"
OUTPUT_DIR = File.join("reference-docs", "scraped", "editions", "iala-historic")
PAGES_DIR = File.join(OUTPUT_DIR, "pages")

def title_to_slug(title)
  title.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/^-|-$/, "")
end

FileUtils.mkdir_p(PAGES_DIR)

puts "Fetching category members for #{CATEGORY}..."
members = IalaApi.get_category_members(CATEGORY)
main_pages = members.select { |m| m["ns"] == 0 }
puts "Found #{main_pages.size} historic-term pages"

index = []
errors = []

main_pages.each_with_index do |member, idx|
  title = member["title"]
  slug = title_to_slug(title)
  page_file = File.join(PAGES_DIR, "#{slug}.json")

  print "[#{idx + 1}/#{main_pages.size}] #{title}"

  if File.exist?(page_file) && File.size(page_file) > 0
    print " (cached)\n"
  else
    print "\n"
    begin
      parse_result = IalaApi.parse_page(title)
      wikitext = IalaApi.get_page_content(title)

      page_doc = {
        "title" => title,
        "parse" => {
          "text" => parse_result[:text],
          "categories" => parse_result[:categories],
          "langlinks" => parse_result[:langlinks]
        },
        "wikitext" => wikitext
      }
      File.write(page_file, JSON.pretty_generate(page_doc))
    rescue => e
      $stderr.puts "  ERROR: #{e.message}"
      errors << { title: title, error: e.message }
    end
  end

  next unless File.exist?(page_file)

  begin
    cached = JSON.parse(File.read(page_file))
    index << {
      "title" => title,
      "categories" => (cached.dig("parse", "categories") || []).map { |c| c["*"]&.gsub("_", " ") }.compact,
      "page_file" => "pages/#{slug}.json"
    }
  rescue => e
    $stderr.puts "  WARN: could not read #{page_file}: #{e.message}"
  end
end

File.write(File.join(OUTPUT_DIR, "index.json"), JSON.pretty_generate(index))
puts "Index written: #{File.join(OUTPUT_DIR, 'index.json')} (#{index.size} entries)"
puts "Errors: #{errors.size}" unless errors.empty?
