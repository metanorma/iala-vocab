require 'yaml'
require 'json'
require 'fileutils'
require 'glossarist'

# Datasets to cross-link. Each pair of datasets with shared termids gets
# either "equivalent" (same definition) or "supersedes"/"superseded_by"
# (different definition) relationships, in both directions.
DATASETS = [
  { id: 'iala-1970-89', urn: 'urn:iala:dictionary:1970-89' },
  { id: 'iala-2009',    urn: 'urn:iala:dictionary:2009' },
  { id: 'iala-2012',    urn: 'urn:iala:dictionary:2012' },
  { id: 'iala-2015',    urn: 'urn:iala:dictionary:2015' },
  { id: 'iala-2016',    urn: 'urn:iala:dictionary:2016' },
  { id: 'iala-2017',    urn: 'urn:iala:dictionary:2017' },
  { id: 'iala-2018',    urn: 'urn:iala:dictionary:2018' },
  { id: 'iala-2022',    urn: 'urn:iala:dictionary:2022' },
  { id: 'iala-2023',    urn: 'urn:iala:dictionary:2023' },
].freeze

def normalize_text(text)
  text.to_s.downcase.gsub(/[^a-z0-9]/, '')
end

def get_eng_definition(docs)
  docs.each do |doc|
    next unless doc
    lang = doc.dig('data', 'language_code') || doc['language_code']
    if lang == 'eng'
      defs = doc['definition']
      if defs && defs.is_a?(Array) && defs[0] && defs[0]['content']
        return defs[0]['content']
      end
    end
  end
  ""
end

# Load all datasets: { termid => { file:, docs:, eng_def: } }
def load_dataset(id)
  concepts = {}
  Dir.glob("datasets/#{id}/concepts/*.yaml").each do |file|
    docs = YAML.load_stream(File.read(file))
    managed = docs[0]
    next unless managed
    termid = managed.dig('data', 'identifier') || managed['termid'] || managed['id']
    next unless termid
    concepts[termid] = { file: file, docs: docs, eng_def: get_eng_definition(docs) }
  rescue => e
    puts "Error parsing #{file}: #{e.message}"
  end
  concepts
end

loaded = DATASETS.map { |ds| [ds[:id], load_dataset(ds[:id])] }.to_h

def write_yaml(file_path, docs)
  content = docs.map { |doc| YAML.dump(doc) }.join("")
  File.write(file_path, content)
end

report = { matched: 0, equivalent: 0, superseded: 0, pairs: {} }

# Walk every unordered pair of datasets once, link in both directions.
DATASETS.combination(2).each do |a, b|
  pair_key = "#{a[:id]} <-> #{b[:id]}"
  pair_counts = { matched: 0, equivalent: 0, superseded: 0 }
  concepts_a = loaded[a[:id]]
  concepts_b = loaded[b[:id]]

  concepts_a.each do |termid, data_a|
    next unless concepts_b.key?(termid)
    data_b = concepts_b[termid]
    pair_counts[:matched] += 1

    norm_a = normalize_text(data_a[:eng_def])
    norm_b = normalize_text(data_b[:eng_def])
    rel_a, rel_b = if norm_a == norm_b && !norm_a.empty?
      pair_counts[:equivalent] += 1
      [
        Glossarist::RelatedConcept.new(
          type: 'equivalent',
          ref: Glossarist::ConceptRef.new(source: b[:urn], id: termid)
        ).to_hash,
        Glossarist::RelatedConcept.new(
          type: 'equivalent',
          ref: Glossarist::ConceptRef.new(source: a[:urn], id: termid)
        ).to_hash,
      ]
    else
      pair_counts[:superseded] += 1
      # Newer supersedes older: caller order doesn't determine direction;
      # we mark it as "supersedes/superseded_by" both ways, but consumers
      # should treat the relationship as edition-agnostic (the diff itself
      # signals the modification, not the link direction).
      [
        Glossarist::RelatedConcept.new(
          type: 'related_concept',
          ref: Glossarist::ConceptRef.new(source: b[:urn], id: termid)
        ).to_hash,
        Glossarist::RelatedConcept.new(
          type: 'related_concept',
          ref: Glossarist::ConceptRef.new(source: a[:urn], id: termid)
        ).to_hash,
      ]
    end

    [data_a, data_b].zip([rel_a, rel_b]).each do |data, rel|
      data[:docs][0]['related'] ||= []
      data[:docs][0]['related'] << rel unless data[:docs][0]['related'].include?(rel)
    end

    report[:matched] += 1
    report[:equivalent] += 1 if norm_a == norm_b && !norm_a.empty?
    report[:superseded] += 1 unless norm_a == norm_b && !norm_a.empty?
  end

  # Persist any modifications made above.
  concepts_a.each_value { |d| write_yaml(d[:file], d[:docs]) if d[:docs][0]['related'] }
  concepts_b.each_value { |d| write_yaml(d[:file], d[:docs]) if d[:docs][0]['related'] }

  report[:pairs][pair_key] = pair_counts
  puts "#{pair_key}: matched=#{pair_counts[:matched]} equivalent=#{pair_counts[:equivalent]} modified=#{pair_counts[:superseded]}"
end

FileUtils.mkdir_p('reference-docs/reports')
File.write('reference-docs/reports/cross-edition.json', JSON.pretty_generate(report))
puts "Updated concepts and wrote report."
