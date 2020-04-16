#!/usr/bin/env ruby
require 'fileutils'

SRC="#{ENV['HOME']}/Music/iTunes/iTunes Media/Music/"
TGT="/Volumes/LaCie/Music/iTunes/iTunes Media/Music/"
DEST="/Volumes/LaCie/Music/to import/"
SKIPS=["Voice Memos", "Podcasts", "Movies", "Audiobooks"]
Dir["#{SRC}/**/*.{mp3,MP3,m4a,WAV}"].each do |src|
	short = src.sub(SRC,'')
	dest = "#{DEST}#{short}"

	if File.exist?("#{TGT}#{short}")
	#	puts "have: #{short}"
		next
	elsif File.exist?(dest)
	#	puts "done: #{short}"
	elsif SKIPS.detect { |skip| short.include?(skip) }
	#	puts "skip: #{short}"
	else
  	puts "todo: #{short}"
  	dirname = dest.split("/")[0..-2].join("/")
  	puts "mkdir: #{dirname}" unless File.exists?(dirname)
  	FileUtils.mkdir_p(dirname) unless File.exist?(dirname)
  	FileUtils.cp(src, dirname)
  end
end
