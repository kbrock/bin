#!/usr/bin/env ruby

# http://blog.semanticart.com/2010/12/24/know-your-fail.html

# you'll probably want to alias this in one of your dotfiles
# i.e. alias st="ruby -I\"lib:test\" search_and_test.rb"
#
# the -I"lib:test" can be important if you get complaints like "no such file to load -- test_helper (MissingSourceFile)"

ack_opts = [
  "-i",              # case insensitive
  "-l",              # just return file names
  "-G _test.rb",     # only search files whose name matches /_test.rb/
  ARGV.join(' '),    # pass along any options we're passed in (usually just the search string)
  "test"            # scope our search to the test directory
].join(" ")

test_files = `ack #{ack_opts}`.split("\n")

if test_files.size > 0
  #taken from testrb
  require 'test/unit'
  (r = Test::Unit::AutoRunner.new(true)).process_args(test_files) or
    abort r.options.banner + " tests..."
  exit r.run

  # original code:
  # puts "Testing: #{test_files.join(" ")}"
  # test_files.each do |file|
  #   load file
  # end
else
  puts "No matches for #{ARGV.join(" ")}"
end