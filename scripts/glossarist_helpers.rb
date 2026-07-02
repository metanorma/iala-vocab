# Helpers for reading/writing multi-doc concept YAML streams via the
# glossarist gem's typed models. Each concept file on disk is a multi-doc
# YAML stream: doc 0 is the ManagedConcept, docs 1+ are LocalizedConcepts
# (one per language). These helpers bridge that on-disk format to the
# library's model API.

require "glossarist"
require "yaml"

module GlossaristHelpers
  module_function

  ConceptFile = Struct.new(:managed, :localized, keyword_init: true)

  # Read a multi-doc concept YAML file into a ConceptFile struct.
  # Returns nil if the file has no managed concept.
  def read_concept_file(path)
    docs = YAML.load_stream(File.read(path))
    return nil if docs.empty? || docs[0].nil?

    managed = Glossarist::ManagedConcept.from_yaml(docs[0].to_yaml)
    localized = docs[1..].compact.map do |d|
      Glossarist::LocalizedConcept.from_yaml(d.to_yaml)
    end
    ConceptFile.new(managed: managed, localized: localized)
  end

  # Write a ConceptFile struct back to disk as a multi-doc YAML stream.
  def write_concept_file(path, concept)
    parts = [concept.managed.to_yaml]
    parts.concat(concept.localized.map(&:to_yaml))
    File.write(path, parts.join)
  end

  # Find a localized concept by language code.
  def find_localized(concept, lang_code)
    concept.localized.find { |lc| lc.data&.language_code == lang_code }
  end

  # Replace (or add) a localized concept in the ConceptFile.
  def upsert_localized!(concept, localized)
    lang = localized.data&.language_code
    raise ArgumentError, "localized has no language_code" unless lang

    existing_idx = concept.localized.index { |lc| lc.data&.language_code == lang }
    if existing_idx
      concept.localized[existing_idx] = localized
    else
      concept.localized << localized
    end
  end
end