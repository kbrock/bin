#!/usr/bin/ruby
# Title: Sublime
# Scheme(s): subl

# Shell (this file)
# Parse a url according to 
# http://blog.macromates.com/2007/the-textmate-url-scheme/
# opens the file

SUBL_PATH="/Applications/Sublime Text.app"
SUBL_BIN_PATH="#{SUBL_PATH}/Contents/SharedSupport/bin/subl"

#require 'logger'
require 'uri'
require 'cgi'

#DEBUG = Logger.new(File.open("#{ENV['HOME']}/sublime_cmd.txt", File::WRONLY | File::APPEND|File::CREAT))

subl_url=ENV['URL']
#DEBUG.info(subl_url)
p=CGI.parse(URI.parse(subl_url).query)
subl_file="#{p["url"].first[7..-1]}:#{p["line"].first}"

#DEBUG.info(subl_file)

ret=`"#{SUBL_BIN_PATH}" "#{subl_file}"`
#DEBUG.info("#{SUBL_BIN_PATH} #{subl_file}")
#DEBUG.info("/handle_url")

exit 0 # the handler has finished successfully
