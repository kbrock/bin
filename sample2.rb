#!/usr/bin/env ruby

require 'optionparser'

module OptLib
  class OptSetter
    def initialize(opts, model, env = ENV)
      @opts  = opts
      @model = model
      @env = env
    end

    def opt(value, *args)
      # support environment variable being specified
      unless args[0].start_with?("-")
        env = args.shift
        ev = @env[env]
        @model.send("#{value}=", ev) if ev
        # add env value onto opts help message
        args.last << " (#{env}=#{ev || "<not set>"})"
      end
      @opts.on(*args) { |v| @model.send("#{value}=", v) }
    end
  end

  def opt(opts, model, env)
    yield OptSetter.new(opts, model, env)
  end
end

class Creds
  attr_accessor :name, :password
end

class MyCode
  include OptLib
  attr_accessor :branch, :check, :filenames

  def creds
    @creds ||= Creds.new
  end

  def parse(argv, env)
    options = OptionParser.new do |opts|
      opts.version = "1.0"
      opt(opts, self, env) do |o|
        o.opt(:branch, "TRAVIS_BRANCH", "--branch STRING", "Branch being built")
        o.opt(:check,  "CHECK",         "--check", "validate that every file on the filesystem has a rule")
      end

      opt(opts, creds, env) do |o|
        o.opt(:name, "PGNAME", "--name", "User Name")
        o.opt(:host, "PGHOST", "--host", "Database host")
      end
    end
    options.parse!(argv)
    
    self.filenames=argv

    self
  end

  def run
    puts "local -- branch: #{branch}, check: #{check}"
    puts "creds -- name: #{creds.name}, creds.password: #{password}"
  end

  def self.run
    new.parse(ARGV, ENV).run
  end
end

MyCode.run
