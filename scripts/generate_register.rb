require 'json'
require 'yaml'
require 'fileutils'

# Read section tree
sections_json = File.read('reference-docs/sections/section-tree.json')
sections_tree = JSON.parse(sections_json)

# Shared fields
shared = {
  'schema_type' => 'glossarist',
  'schema_version' => '3',
  'languages' => ['eng'],
  'languageOrder' => ['eng'],
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

FileUtils.mkdir_p('datasets/iala-1970-89')
File.write('datasets/iala-1970-89/register.yaml', format_yaml(register_1970_89))

# 2023
register_2023 = shared.merge({
  'id' => 'iala-2023',
  'year' => 2023,
  'urn' => 'urn:iala:dictionary:2023',
  'status' => 'current'
})

FileUtils.mkdir_p('datasets/iala-2023')
File.write('datasets/iala-2023/register.yaml', format_yaml(register_2023))

puts "Registers generated successfully."
