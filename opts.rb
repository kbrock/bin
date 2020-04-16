#!/usr/bin/env ruby

require 'optparse'

class Opts
  attr_accessor :options
  attr_accessor :args

  def initialize(options = nil)
    @options = options
  end

  def run
    puts "options: #{options.inspect}"
    puts "args:    #{args.inspect}"
  end

  def parse(args, env)
    self.args = args.dup
    self.options ||= {}

    options[:extras] = true

    OptionParser.new do |opts|
      opts.program_name = File.basename($0)
      opts.banner = "Usage: #{File.basename($0)} [options] [arg1] [arg2]"
      opts.on("-v", "--[no-]verbose", "Run verbosely") { |v| options[:verbose] = v }
      opts.on("-x", "--[no-]extras", "Run with extras (default: #{options[:extras]})") { |v| options[:extras] = v }
    end.parse!(self.args)

    self
  end
end

if __FILE__ == $0
  Opts.new.parse(ARGV, ENV).run
end
