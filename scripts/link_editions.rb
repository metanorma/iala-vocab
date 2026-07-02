require "json"
require "fileutils"
require_relative "glossarist_helpers"

# Datasets to cross-link. Each pair of datasets with shared termids gets
# either "equivalent" (same definition) or "related_concept" (different
# definition) relationships, in both directions.
DATASETS = [
  { id: "iala-1970-89", urn: "urn:iala:dictionary:1970-89" },
  { id: "iala-2009",    urn: "urn:iala:dictionary:2009" },
  { id: "iala-2012",    urn: "urn:iala:dictionary:2012" },
  { id: "iala-2015",    urn: "urn:iala:dictionary:2015" },
  { id: "iala-2016",    urn: "urn:iala:dictionary:2016" },
  { id: "iala-2017",    urn: "urn:iala:dictionary:2017" },
  { id: "iala-2018",    urn: "urn:iala:dictionary:2018" },
  { id: "iala-2022",    urn: "urn:iala:dictionary:2022" },
  { id: "iala-2023",    urn: "urn:iala:dictionary:2023" },
].freeze

def normalize_text(text)
  text.to_s.downcase.gsub(/[^a-z0-9]/, "")
end

def get_eng_definition(concept)
  eng = concept.localized.find { |lc| lc.data&.language_code == "eng" }
  return "" unless eng && eng.data&.definition&.any?

  eng.data.definition.first&.content || ""
end

def concept_identifier(concept)
  concept.managed.data&.id || concept.managed.id
end

# Load all datasets: { termid => { file:, concept:, eng_def: } }
def load_dataset(id)
  concepts = {}
  Dir.glob("datasets/#{id}/concepts/*.yaml").each do |file|
    concept = GlossaristHelpers.read_concept_file(file)
    next unless concept && concept.managed

    termid = concept_identifier(concept)
    next unless termid

    concepts[termid] = {
      file: file,
      concept: concept,
      eng_def: get_eng_definition(concept),
    }
  rescue => e
    warn "Error parsing #{file}: #{e.message}"
  end
  concepts
end

loaded = DATASETS.map { |ds| [ds[:id], load_dataset(ds[:id])] }.to_h

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

    rel_type = if norm_a == norm_b && !norm_a.empty?
                 pair_counts[:equivalent] += 1
                 "equivalent"
               else
                 pair_counts[:superseded] += 1
                 "related_concept"
               end

    [data_a, data_b].zip([b, a]).each do |data, other_ds|
      related = data[:concept].managed.related || []
      already = related.any? do |r|
        r.type == rel_type &&
          r.ref&.source == other_ds[:urn] &&
          r.ref&.id == termid
      end
      next if already

      data[:concept].managed.related << Glossarist::V3::RelatedConcept.new(
        type: rel_type,
        ref: Glossarist::V3::ConceptRef.new(source: other_ds[:urn], id: termid),
      )
      data[:dirty] = true
    end

    report[:matched] += 1
    report[:equivalent] += 1 if rel_type == "equivalent"
    report[:superseded] += 1 if rel_type == "related_concept"
  end

  # Persist only concepts that gained a new edge in this pair pass.
  concepts_a.each_value { |d| GlossaristHelpers.write_concept_file(d[:file], d[:concept]) if d[:dirty] }
  concepts_b.each_value { |d| GlossaristHelpers.write_concept_file(d[:file], d[:concept]) if d[:dirty] }

  report[:pairs][pair_key] = pair_counts
  puts "#{pair_key}: matched=#{pair_counts[:matched]} equivalent=#{pair_counts[:equivalent]} modified=#{pair_counts[:superseded]}"
end

FileUtils.mkdir_p("reference-docs/reports")
File.write("reference-docs/reports/cross-edition.json", JSON.pretty_generate(report))
puts "Updated concepts and wrote report."