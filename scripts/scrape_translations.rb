#!/usr/bin/env ruby
require_relative "iala_api"
require "json"
require "fileutils"
require "nokogiri"

LANGS = {
  "fr" => { category: "Classement_alphabétique", code: "fra" },
  "es" => { category: "Indice_alfabeto_Español", code: "spa" }
}

LANGS.each do |suffix, config|
  lang = config[:code]
  out_dir = File.join("reference-docs", "translations", lang)
  FileUtils.mkdir_p(out_dir)
  
  puts "=== Scraping #{suffix.upcase} (#{config[:category]}) ==="
  members = IalaApi.get_category_members(config[:category])
  main_pages = members.select { |m| m["ns"] == 0 }
  puts "Found #{main_pages.size} pages"
  
  index = []
  main_pages.each_with_index do |member, idx|
    full_title = member["title"]
    english_title = full_title.sub(/\/#{suffix}$/, "")
    
    print "[#{idx+1}/#{main_pages.size}] #{full_title}"
    
    slug = full_title.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/^-|-$/, "")
    page_file = File.join(out_dir, "#{slug}.json")
    
    if File.exist?(page_file) && File.size(page_file) > 0
      print " (cached)\n"
    else
      print "\n"
      begin
        parse_result = IalaApi.parse_page(full_title)
        wikitext = IalaApi.get_page_content(full_title)
        
        page_doc = {
          "title" => full_title,
          "english_title" => english_title,
          "lang" => lang,
          "parse" => {
            "text" => parse_result[:text],
            "categories" => parse_result[:categories],
            "langlinks" => parse_result[:langlinks]
          },
          "wikitext" => wikitext
        }
        
        File.write(page_file, JSON.pretty_generate(page_doc))
      rescue => e
        puts "  ERROR: #{e.message}"
      end
    end
    
    # Extract definition for index
    if File.exist?(page_file)
      cached = JSON.parse(File.read(page_file))
      html = cached.dig("parse", "text") || ""
      doc = Nokogiri::HTML(html)
      parser_output = doc.css(".mw-parser-output").first || doc
      content = parser_output.css("p, ul, ol").map(&:text).join(" ").strip[0..200]
      
      index << {
        "english_title" => english_title,
        "title" => full_title,
        "lang" => lang,
        "definition_preview" => content,
        "page_file" => "#{lang}/#{slug}.json"
      }
    end
  end
  
  index_file = File.join(out_dir, "index.json")
  File.write(index_file, JSON.pretty_generate(index))
  puts "Index saved: #{index_file} (#{index.size} entries)"
end
