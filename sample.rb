#!/usr/bin/env ruby

require 'optparse'

module Sample
  class Runner
    attr_accessor :arguments, :options

    def self.start
      new.start
    end

    def initialize(arguments = ARGV)
      @options={}
      @arguments = arguments
    end

    def start
      self.options = parse_arguments(arguments)

      puts options.inspect
      puts @arguments.join(" ")
    end

    def parse_arguments(arguments)
      options = {}

      OptionParser.new do |opt|
        opt.banner = "Usage: aab [-n #] [-c #] [-h host] [-t token] [-apple] [-google]"
        opt.on('-n', '--requests=count',   Integer, "Number of requests (default: #{requests})")  { |v| options[:requests] = v }
        opt.on('-t', '--token=token',      String, 'The base for the token')                      { |v| options[:token]    = v.strip}
        opt.on(      '--vm',                       'Use local vm')                                { |v| options[:host]     = '10.0.4.1:1980'}
        opt.parse!(arguments)
      end

      # if arguments.first && arguments.first[0] != '-'
      #   options[:x] = arguments.first
      # end

      options
    end

    def requests
      options[:requests] || 5
    end

    def token
      options[:token]
    end
  end
end

if __FILE__ == $0
  Sample::Runner.start
end
