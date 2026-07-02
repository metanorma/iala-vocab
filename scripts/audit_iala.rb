require 'yaml'
require 'fileutils'

datasets = %w[
  iala-1970-89 iala-2009 iala-2012 iala-2015
  iala-2016 iala-2017 iala-2018 iala-2022 iala-2023
].map { |id| "datasets/#{id}/concepts" }

summary = {
  datasets: {},
  critical_errors: 0
}

datasets.each do |ds|
  files = Dir.glob("#{ds}/*.yaml")
  termids = []
  domains_counts = Hash.new(0)
  related_count = 0
  schema_errors = 0
  
  files.each do |file|
    begin
      docs = YAML.load_stream(File.read(file))
      managed = docs[0]
      unless managed
        puts "Error: No managed doc in #{file}"
        schema_errors += 1
        next
      end
      
      termid = managed.dig('data', 'identifier') || managed['termid'] || managed['id']
      if termid.nil? || termid.to_s.strip.empty?
        puts "Error: Missing termid in #{file}"
        schema_errors += 1
      else
        termids << termid
      end

      domains = managed.dig('data', 'domains') || managed['domains'] || []
      domains.each do |dom|
        domains_counts[dom['concept_id'] || 'unknown'] += 1
      end

      related = managed['related'] || []
      related_count += 1 unless related.empty?

      localized_docs = docs[1..-1] || []
      localized_docs.each do |doc|
        data = doc["data"] || {}
        unless data["terms"] && data["terms"].is_a?(Array) && !data["terms"].empty?
          lang = data["language_code"]
          puts "Error: Missing terms in #{file} (#{lang})"
          schema_errors += 1
        end
        if data["definition"]
          unless data["definition"].is_a?(Array) && data["definition"].all? { |d| d.is_a?(Hash) && d.key?('content') }
            lang = data["language_code"]
            puts "Error: Invalid definition structure in #{file} (#{lang})"
            schema_errors += 1
          end
        end
      end
    rescue => e
      puts "Exception parsing #{file}: #{e.message}"
      schema_errors += 1
    end
  end
  
  duplicates = termids.group_by(&:itself).select { |_, v| v.size > 1 }.keys
  if duplicates.any?
    puts "Error: Duplicate termids in #{ds}: #{duplicates.join(', ')}"
    schema_errors += duplicates.size
  end
  
  summary[:datasets][ds] = {
    concept_count: files.size,
    duplicate_termids: duplicates.size,
    schema_errors: schema_errors,
    domains: domains_counts,
    related_count: related_count
  }
  
  summary[:critical_errors] += schema_errors
end

puts "\n=== AUDIT REPORT ==="
summary[:datasets].each do |ds, stats|
  puts "\nDataset: #{ds}"
  puts "Concept count: #{stats[:concept_count]}"
  puts "Schema errors: #{stats[:schema_errors]}"
  puts "Duplicate termids: #{stats[:duplicate_termids]}"
  puts "Concepts with cross-edition relationships: #{stats[:related_count]}"
  puts "Domain assignments:"
  stats[:domains].sort_by { |k, v| -v }.each do |k, v|
    puts "  - #{k}: #{v}"
  end
end

puts "\nTotal critical errors: #{summary[:critical_errors]}"

if summary[:critical_errors] > 0
  exit 1
else
  exit 0
end
