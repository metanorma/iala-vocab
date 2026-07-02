require 'json'
require 'yaml'
require 'fileutils'

# Read section tree
sections_json = File.read('reference-docs/scraped/sections/section-tree.json')
sections_tree = JSON.parse(sections_json)

# Shared fields
shared = {
  'schema_type' => 'glossarist',
  'schema_version' => '3',
  'languages' => ['eng', 'fra', 'spa', 'deu'],
  'languageOrder' => ['eng', 'fra', 'spa', 'deu'],
  'ordering' => 'systematic',
  'sections' => sections_tree
}

# 1970-89
register_1970_89 = shared.merge({
  'id' => 'iala-1970-89',
  'year' => 1989,
  'urn' => 'urn:iala:dictionary:1970-89',
  'status' => 'retired'
})

# Move keys to top to make it look nice, though Hash#merge maintains order in Ruby 2+ if we do it right.
def format_yaml(data)
  # Ensure specific key order
  ordered_keys = %w[schema_type schema_version id year urn status languages languageOrder ordering sections]
  ordered_data = {}
  ordered_keys.each do |k|
    ordered_data[k] = data[k] if data.key?(k)
  end
  # Add remaining keys
  (data.keys - ordered_keys).each do |k|
    ordered_data[k] = data[k]
  end
  YAML.dump(ordered_data)
end

EDITIONS = [
  { 'id' => 'iala-1970-89', 'year' => 1989, 'urn' => 'urn:iala:dictionary:1970-89', 'status' => 'retired' },
  { 'id' => 'iala-2009',    'year' => 2009, 'urn' => 'urn:iala:dictionary:2009',    'status' => 'retired' },
  { 'id' => 'iala-2012',    'year' => 2012, 'urn' => 'urn:iala:dictionary:2012',    'status' => 'retired' },
  { 'id' => 'iala-2015',    'year' => 2015, 'urn' => 'urn:iala:dictionary:2015',    'status' => 'retired' },
  { 'id' => 'iala-2016',    'year' => 2016, 'urn' => 'urn:iala:dictionary:2016',    'status' => 'retired' },
  { 'id' => 'iala-2017',    'year' => 2017, 'urn' => 'urn:iala:dictionary:2017',    'status' => 'retired' },
  { 'id' => 'iala-2018',    'year' => 2018, 'urn' => 'urn:iala:dictionary:2018',    'status' => 'retired' },
  { 'id' => 'iala-2022',    'year' => 2022, 'urn' => 'urn:iala:dictionary:2022',    'status' => 'retired' },
  { 'id' => 'iala-2023',    'year' => 2023, 'urn' => 'urn:iala:dictionary:2023',    'status' => 'current' },
].freeze

EDITIONS.each do |e|
  reg = shared.merge(e)
  FileUtils.mkdir_p("datasets/#{e['id']}")
  File.write("datasets/#{e['id']}/register.yaml", format_yaml(reg))
end

puts "Generated #{EDITIONS.size} registers."
