require 'yaml'
require 'json'
require 'fileutils'

dir_1970 = "datasets/iala-1970-89/concepts"
dir_2023 = "datasets/iala-2023/concepts"
urn_1970 = "urn:iala:dictionary:1970-89"
urn_2023 = "urn:iala:dictionary:2023"

def normalize_text(text)
  text.to_s.downcase.gsub(/[^a-z0-9]/, '')
end

def get_eng_definition(docs)
  docs.each do |doc|
    next unless doc
    if doc['language_code'] == 'eng'
      defs = doc['definition']
      if defs && defs.is_a?(Array) && defs[0] && defs[0]['content']
        return defs[0]['content']
      end
    end
  end
  ""
end

concepts_1970 = {}
Dir.glob("#{dir_1970}/*.yaml").each do |file|
  begin
    docs = YAML.load_stream(File.read(file))
    managed = docs[0]
    next unless managed
    termid = managed['termid']
    next unless termid
    
    eng_def = get_eng_definition(docs)
    concepts_1970[termid] = { file: file, docs: docs, eng_def: eng_def }
  rescue => e
    puts "Error parsing #{file}: #{e.message}"
  end
end

concepts_2023 = {}
Dir.glob("#{dir_2023}/*.yaml").each do |file|
  begin
    docs = YAML.load_stream(File.read(file))
    managed = docs[0]
    next unless managed
    termid = managed['termid']
    next unless termid
    
    eng_def = get_eng_definition(docs)
    concepts_2023[termid] = { file: file, docs: docs, eng_def: eng_def }
  rescue => e
    puts "Error parsing #{file}: #{e.message}"
  end
end

matched_count = 0
identical_count = 0
superseded_count = 0

# Note on multi-doc YAML dumping:
# YAML.dump(doc) will prefix with `---` but Ruby's YAML writer doesn't add it natively for consecutive dumps sometimes.
# Actually, YAML.dump(doc) adds `---` at the beginning of each document, which is correct for multi-doc.

def write_yaml(file_path, docs)
  # Prevent trailing newline issues or missing dashes
  content = docs.map do |doc|
    yaml_str = YAML.dump(doc)
    # Remove any extra empty document artifacts if they appear
    yaml_str
  end.join("")
  File.write(file_path, content)
end

concepts_1970.each do |termid, data_1970|
  if concepts_2023.key?(termid)
    matched_count += 1
    data_2023 = concepts_2023[termid]
    
    norm_1970 = normalize_text(data_1970[:eng_def])
    norm_2023 = normalize_text(data_2023[:eng_def])
    
    rel_1970 = []
    rel_2023 = []
    
    if norm_1970 == norm_2023 && !norm_1970.empty?
      identical_count += 1
      rel_1970 << { 'type' => 'identical', 'ref' => { 'source' => urn_2023, 'concept_id' => termid } }
      rel_2023 << { 'type' => 'identical', 'ref' => { 'source' => urn_1970, 'concept_id' => termid } }
    else
      superseded_count += 1
      rel_1970 << { 'type' => 'superseded_by', 'ref' => { 'source' => urn_2023, 'concept_id' => termid } }
      rel_2023 << { 'type' => 'supersedes', 'ref' => { 'source' => urn_1970, 'concept_id' => termid } }
    end
    
    # Update 1970
    data_1970[:docs][0]['related'] ||= []
    rel_1970.each do |r|
      data_1970[:docs][0]['related'] << r unless data_1970[:docs][0]['related'].include?(r)
    end
    write_yaml(data_1970[:file], data_1970[:docs])
    
    # Update 2023
    data_2023[:docs][0]['related'] ||= []
    rel_2023.each do |r|
      data_2023[:docs][0]['related'] << r unless data_2023[:docs][0]['related'].include?(r)
    end
    write_yaml(data_2023[:file], data_2023[:docs])
  end
end

report = {
  matched: matched_count,
  identical: identical_count,
  superseded: superseded_count
}

FileUtils.mkdir_p('reference-docs')
File.write('reference-docs/cross-edition-report.json', JSON.pretty_generate(report))
puts "Updated concepts and wrote report."
