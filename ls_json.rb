#!/usr/bin/env ruby

require 'json'

dir=ARGV[0]
root=ARGV[1]||"."
depth=ARGV[2]||5

if "#{dir}" == ""
  puts "usage: ls_json.rb dir [web_root] [depth]"
  exit 1
end

dir = File.expand_path(dir)
root = File.expand_path(root)
depth = depth.to_i


#does match belong here?
def node_info(root, dir, match, depth)
  if File.directory?(dir) && (depth - 1) > 0
    {
      type: "dir",
      name: dir.split('/').last,
      children: Dir["#{dir}/*"].map { |child|
        node_info(root, child, match, depth - 1)
      }.compact 
    }
  elsif dir =~ match
    {
      type: "file",
      name: dir.split('/').last,
      link: dir.gsub(root,'')
    }
  end
end

def trim_children(node)
  if node[:type] == "dir"
    node[:children] = node[:children].map {|ch| trim_children(ch) }.compact
    if node[:children].size == 0
      nil
    elsif node[:children].size == 1
      node[:children].first
    else
      node
    end
  else #file
    node
  end
end

#note: calling this after trimming all the children
# that way we don't get a compressed name
def trim_names(node, parent=nil)
  if node[:type] == "dir"
    node[:children] = node[:children].map { |ch| trim_names(ch, node[:name]) }
  end
  node[:name] = node[:name].gsub(/\.(html|md)$/,'')
  node[:name] = node[:name].gsub(/^#{parent}[-_.]?/,'') if parent && node[:name] != parent
  node
end

nodes = node_info(File.expand_path(root),File.expand_path(dir), /\.(html|md)$/, depth)
nodes = trim_children(nodes)
nodes = trim_names(nodes)
# if only 1 child, simplify
# remove name from child nodes (e.)
puts JSON.pretty_generate(nodes)
