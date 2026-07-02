#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "iala_api"
require "nokogiri"
require "json"
require "fileutils"
require "set"

# Authoritative top-level section names (user specification)
TOP_LEVEL_SECTIONS = {
  "0" => "Overview",
  "1" => "General Terms",
  "2" => "Visual Aids",
  "3" => "Audible Aids",
  "4" => "Radio Aids",
  "5" => "RCM & Reliability",
  "6" => "Power Supplies",
  "7" => "Civil Engineering",
  "8" => "Floating Equipment",
  "9" => "VTS",
  "10" => "e-Navigation",
  "11" => "AIS",
  "12" => "Heritage"
}.freeze

OUTPUT_DIR = File.join(File.dirname(__FILE__), "..", "reference-docs", "scraped", "sections")
OUTPUT_FILE = File.join(OUTPUT_DIR, "section-tree.json")

def extract_chapter_number(href)
  # /wiki/dictionary/index.php/Category:Chapter_1_General_Terms → "1"
  # /wiki/dictionary/index.php/Category:Chapter_10_e-Navigation → "10"
  href.match(/Category:Chapter_(\d+)_/)&.captures&.first
end

def extract_subsection_id(href)
  # /wiki/dictionary/index.php/Category:1.1_Basic_Terms → "1.1"
  # /wiki/dictionary/index.php/Category:10.1_General_e-Navigation_terms → "10.1"
  href.match(/Category:(\d+\.\d+)[_:]/)&.captures&.first
end

def extract_subsection_name(link_text)
  # "1.1 Basic Terms" → "Basic Terms"
  # "2.6 Visual Aids in general: Buoyage and Beaconage" → "Visual Aids in general: Buoyage and Beaconage"
  link_text.strip.sub(/^\d+\.\d+\s+/, "")
end

def parse_subsections(children_div)
  return [] unless children_div

  children_div.css("> .CategoryTreeSection").filter_map do |section|
    item = section.at_css(".CategoryTreeItem a")
    next unless item

    href = item["href"] || ""
    text = item.text.strip
    sub_id = extract_subsection_id(href)
    next unless sub_id

    sub_name = extract_subsection_name(text)

    # Recurse into deeper children if any
    deeper_div = section.at_css("> .CategoryTreeChildren")
    deeper_children = parse_subsections(deeper_div)

    { "id" => sub_id, "names" => { "eng" => sub_name }, "children" => deeper_children }
  end
end

def build_section_tree
  puts "Fetching Chapter_Index page via IalaApi..."
  page_data = IalaApi.parse_page("Chapter_Index")
  html = page_data[:text]
  raise "No HTML content returned from API" if html.nil? || html.empty?

  puts "Parsing CategoryTree HTML with Nokogiri..."
  doc = Nokogiri::HTML(html)

  # The root is: .CategoryTreeTag > .CategoryTreeSection (IALA_Dictionary)
  iala_root = doc.at_css(".CategoryTreeTag > .CategoryTreeSection")
  raise "Could not find IALA Dictionary root CategoryTreeSection" unless iala_root

  top_children_div = iala_root.at_css("> .CategoryTreeChildren")
  raise "Could not find top-level CategoryTreeChildren" unless top_children_div

  # Collect chapters from the tree, merging duplicate chapter numbers (Chapter 12 appears twice)
  chapters_from_tree = {}

  top_children_div.css("> .CategoryTreeSection").each do |section|
    item = section.at_css(".CategoryTreeItem a")
    next unless item

    href = item["href"] || ""
    chapter_num = extract_chapter_number(href)
    next unless chapter_num

    children_div = section.at_css("> .CategoryTreeChildren")
    subsections = parse_subsections(children_div)

    if chapters_from_tree.key?(chapter_num)
      # Merge subsections: keep first occurrence of each id (e.g., Chapter 12 appears twice)
      existing_ids = chapters_from_tree[chapter_num]["children"].map { |c| c["id"] }.to_set
      subsections.each do |sub|
        next if existing_ids.include?(sub["id"])

        chapters_from_tree[chapter_num]["children"] << sub
        existing_ids << sub["id"]
      end
    else
      chapters_from_tree[chapter_num] = { "id" => chapter_num, "children" => subsections }
    end
  end

  # Build the authoritative 13-section tree (ids 0-12)
  TOP_LEVEL_SECTIONS.map do |id, name|
    chapter_data = chapters_from_tree[id] || {}
    children = chapter_data["children"] || []
    { "id" => id, "names" => { "eng" => name }, "children" => children }
  end
end

# Main
section_tree = build_section_tree

FileUtils.mkdir_p(OUTPUT_DIR)
File.write(OUTPUT_FILE, JSON.pretty_generate(section_tree))

puts "\nSection tree written to #{OUTPUT_FILE}"
puts "Top-level sections: #{section_tree.length}"
puts ""
section_tree.each do |section|
  puts "  #{section['id']}: #{section['names']['eng']} (#{section['children'].length} children)"
end
