#!/usr/bin/env ruby

require 'uri'

dir=ARGV[0]
root=ARGV[1]||"."

if "#{root}" == ""
  puts "usage: ls_index.rb dir [root]"
  exit 1
end

dir = File.expand_path(dir)
root = File.expand_path(root)
path = dir.gsub(root,'')

File.open("#{dir}/index.html", "w") do |f|
    f.write "<html>"
    f.write "<head><title>#{path}</title></head>"
    f.write "<body><h1>#{path}</h1><ul>"
    Dir["#{dir}/*"].each do |file|
      rel_name=file #.gsub(" ","%20")#.gsub(root,'')
      rel_name = URI.escape(rel_name)
      f.write %{<li><img src="#{rel_name}"><a href="#{rel_name}">#{file.gsub(dir,'')}</a></li>}
    end
    f.write "</ul></body></html>"
end

