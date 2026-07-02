require 'json'
require 'yaml'
require 'fileutils'

def process_edition(edition)
  index_path = "reference-docs/scraped/editions/#{edition}/index.json"
  return unless File.exist?(index_path)

  index = JSON.parse(File.read(index_path))
  
  index.each do |concept|
    slug = concept['page_file'].sub('pages/', '').sub('.json', '')
    termid = concept['numeric_code']
    termid = slug if termid.nil? || termid.empty?
    
    page_file = "reference-docs/scraped/editions/#{edition}/#{concept['page_file']}"
    
    unless File.exist?(page_file)
      puts "Missing page file: #{page_file}"
      next
    end
    
    page_data = JSON.parse(File.read(page_file))
    categories = page_data.dig('parse', 'categories') || []
    category_names = categories.map { |c| c['*'].gsub('_', ' ') }
    
    dates = []
    approval = nil
    
    category_names.each do |cat|
      case cat
      when 'IALA Dictionary 1970-89 Edition'
        dates << { 'type' => 'accepted', 'date' => '1970-1989' }
      when 'IALA Dictionary 2009 Edition'
        dates << { 'type' => 'amended', 'date' => '2009' }
      when 'IALA Dictionary 2012 Revision'
        dates << { 'type' => 'amended', 'date' => '2012' }
      when 'IALA Dictionary 2015 Revision'
        dates << { 'type' => 'amended', 'date' => '2015' }
      when 'IALA Dictionary 2016 Revision'
        dates << { 'type' => 'amended', 'date' => '2016' }
      when 'IALA Dictionary 2017 Revision'
        dates << { 'type' => 'amended', 'date' => '2017' }
      when 'IALA Dictionary 2018 Revision'
        dates << { 'type' => 'amended', 'date' => '2018' }
      when 'IALA Dictionary 2022 Revision'
        dates << { 'type' => 'amended', 'date' => '2022' }
      when 'IALA Dictionary 2023 Revision'
        dates << { 'type' => 'amended', 'date' => '2023' }
      when 'Approved by Dictionary Management Group'
        approval = 'Dictionary Management Group'
      when 'Approved by DWG'
        approval = 'Dictionary Working Group'
      end
    end
    
    dates.uniq!
    
    if dates.empty? && approval.nil?
      next
    end
    
    yaml_files = Dir.glob("datasets/#{edition}/concepts/#{termid}*.yaml")
    if yaml_files.empty?
      # Try globbing more loosely
      yaml_files = Dir.glob("datasets/#{edition}/concepts/*#{termid}*.yaml")
    end
    
    yaml_file = yaml_files.first
    unless yaml_file
      puts "Missing yaml file for termid: #{termid}"
      next
    end
    
    docs = YAML.load_stream(File.read(yaml_file))
    next if docs.empty?
    
    docs[0]['dates'] = dates unless dates.empty?
    docs[0]['approval'] = approval if approval
    
    File.open(yaml_file, 'w') do |f|
      docs.each do |doc|
        f.write YAML.dump(doc)
      end
    end
  end
end

['iala-1970-89', 'iala-2023'].each do |ed|
  process_edition(ed)
end
