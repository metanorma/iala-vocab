#!/usr/bin/env ruby
require "httparty"
require "json"
require "fileutils"
require "set"

BASE = "https://www.iala.int"
IMG_DIR = File.join("public", "images", "iala")
EDITIONS_DIR = File.join("reference-docs", "scraped", "editions")

FileUtils.mkdir_p(IMG_DIR)

# UI icon patterns to skip
SKIP_PATTERNS = [
  /Geographylogo\.png/i,
  /^\d{1,2}px-/,           # 16px-, 25px- prefixes
  /^spacer\./i,
  /^blank\./i,
].freeze

def skip_image?(filename)
  SKIP_PATTERNS.any? { |pat| pat.match?(filename) }
end

# Step 1: Collect all unique image URLs from cached pages
image_urls = Set.new
["iala-1970-89", "iala-2023"].each do |edition|
  pages_dir = File.join(EDITIONS_DIR, edition, "pages")
  next unless Dir.exist?(pages_dir)

  Dir.glob(File.join(pages_dir, "*.json")).each do |fpath|
    page = JSON.parse(File.read(fpath))
    html = page.dig("parse", "text") || ""
    html.scan(/src="([^"]*\/images\/[^"]*)"/).flatten.each do |src|
      image_urls << src
    end
  end
end

puts "Found #{image_urls.size} unique image URLs"

# Step 2: Download each image
image_map = {}
downloaded = 0
skipped = 0
filtered = 0
errors = 0

image_urls.to_a.sort.each_with_index do |src, idx|
  # Normalize URL: strip thumb wrapper to get full-resolution version
  full_src = src.gsub(/\/thumb\//, "/").gsub(/\/\d+px-[^\/]+$/, "")

  # Extract filename from full_src
  filename = full_src.split("/").last
  next if filename.nil? || filename.empty?

  # Sanitize filename
  filename = filename.gsub(/[^a-zA-Z0-9._-]/, "_")

  # Filter UI icons
  if skip_image?(filename)
    filtered += 1
    next
  end

  local_path = File.join(IMG_DIR, filename)
  relative_path = "/iala-vocab/images/iala/#{filename}"

  print "\r[#{idx + 1}/#{image_urls.size}] #{filename[0..50].ljust(51)}  "
  $stdout.flush

  if File.exist?(local_path) && File.size(local_path) > 0
    skipped += 1
    image_map[src] = relative_path
    image_map[full_src] = relative_path
    next
  end

  begin
    url = src.start_with?("http") ? src : "#{BASE}#{src}"
    response = HTTParty.get(url, timeout: 30)

    if response.code == 200 && response.body.size > 1024  # skip <1KB files
      FileUtils.mkdir_p(File.dirname(local_path))
      File.binwrite(local_path, response.body)
      image_map[src] = relative_path
      image_map[full_src] = relative_path
      downloaded += 1
      sleep 0.1
    elsif response.code == 200
      puts "\n  SKIP (too small, #{response.body.size}B): #{filename}"
      filtered += 1
    else
      puts "\n  WARN #{response.code}: #{url}"
      errors += 1
    end
  rescue => e
    puts "\n  ERROR: #{e.message} for #{src}"
    errors += 1
  end
end

puts ""
puts "Done — Downloaded: #{downloaded}, Skipped (cached): #{skipped}, Filtered (icons/tiny): #{filtered}, Errors: #{errors}"

# Save mapping
map_file = File.join("reference-docs", "reports", "image-map.json")
File.write(map_file, JSON.pretty_generate(image_map.sort.to_h))
puts "Image map saved to: #{map_file} (#{image_map.size} entries)"
