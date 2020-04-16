#!/usr/bin/env ruby

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
        f.write %{<li><a href="#{file.gsub(root,'')}">#{file.gsub(dir,'')}</a></li>}
    end
    f.write "</ul></body></html>"
end

