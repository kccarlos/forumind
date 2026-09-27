#!/usr/bin/env ruby
# Print a UUID-free, stable JSON dump of an .xcodeproj's object graph.
# Used by check-project-drift.sh to compare projects whose object IDs differ
# (scripts/generate_project.rb mints random UUIDs on every run).
require "json"
require "xcodeproj"

UUID = /\A[0-9A-F]{24}\z/

def scrub(value)
  case value
  when Hash then value.to_h { |k, v| [k, scrub(v)] }
  when Array then value.map { |v| scrub(v) }
  when String then value.match?(UUID) ? "<uuid>" : value
  else value
  end
end

path = ARGV.fetch(0)
tree = Xcodeproj::Project.open(path).to_tree_hash
tree["rootObject"]&.delete("displayName") if tree.is_a?(Hash)
puts JSON.pretty_generate(scrub(tree))
