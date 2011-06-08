#!/usr/bin/env watchr
#RUN_ALL_TESTS||=true

unless defined?(GROWL)
  ENV["WATCHR"] = "1"
  GROWL=`which growlnotify`.chomp
  IMAGE_DIR=File.expand_path("~/.watchr_images/")
  #SPORK=true
end

def growl(message,title=nil,image=nil)
  title ||= "Watchr Test Results"
  message.gsub! /\[[0-9]+?m/, ''
  image =
    if image == true
      "#{IMAGE_DIR}/pass.png"
    elsif image == false || image.nil?
      "#{IMAGE_DIR}/fail.png"
    else
      image
    end
  options = "-n Watchr --image '#{image}' -m '#{message}' '#{title}'"
  run "#{GROWL} #{options}"
end

def clear
  #system('clear')
end

def run(cmd,verbose=true)
  puts
  puts("# #{cmd}")
  puts
  ret=[]
  IO.popen(cmd) do |output| 
      while line = output.gets do
        puts line if verbose
        ret << line
      end
  end
  ret #join("\n")
end

def run_test_file(file)
  clear
  if defined?(SPORK)
    result = run %{bundle exec testdrb #{file}}
  else
    result = run %{ruby -I"lib:test" -rubygems #{file}}
  end
  growl *units_message(result)
  #puts result
end

def run_all_tests
  clear
  result = run "rake test"
  growl *units_message(result)
  #puts result
end

def units_message(result)
  #failures=result.count { |s| s =~/Failure/ }
  #errors=result.count { |s| s =~/Error/ }
  #{}"#{failures} failures, #{errors} errors"
  row=result.detect { |s| s =~/ failures, / }
  return 'xxx' if row.nil?
  row =~ /(\d+) tests, \d+ assertions.*(\d+) failures, (\d+) errors/
  tot=$1.to_i
  fail=$2.to_i + $3.to_i
  ["#{tot-fail}/#{tot} pass", nil, fail==0]
end

def run_feature_file(file)
  clear
  #result = run %{bundle exec cucumber #{file} RAILS_ENV=cucumber}
  result = run %{rake db:test:prepare ; bundle exec cucumber #{file} RAILS_ENV=cucumber}
  growl 'cuked'
end

def run_all_features
  return if !cucumber?
  clear
  result=run("rake cucumber:all")
  growl 'cucumbered', 'spork'
end

def related_test_files(path)
  Dir['test/**/*.rb'].select { |file| file =~ /#{File.basename(path).split(".").first}_test.rb/ }
end

def run_suite
  run_all_tests
  run_all_features
end

def cucumber?
  true
  #Dir.entries(File.dirname(__FILE__) + '/test').include? 'features'
end

watch('test/.*/.*_test\.rb') { |m| run_test_file(m[0]) }
#watch('app/.*/.*\.rb') { |m| related_test_files(m[0]).map {|tf| run_test_file(tf) } }
watch('features/.*\.feature') { |m| run_feature_file(m[0]) }
watch('test/test_helper\.rb') { run_all_tests } if defined?(RUN_ALL_TEST)

if defined?(RUN_ALL_TESTS)
  clear

  # Ctrl-\
  Signal.trap 'QUIT' do
    puts " --- Running all tests ---\n\n"
    run_all_tests
  end

  @interrupted = false

  # Ctrl-C
  Signal.trap 'INT' do
    if @interrupted then
      @wants_to_quit = true
      abort("\n")
    else
      puts "Interrupt a second time to quit"
      @interrupted = true
      Kernel.sleep 1.5
      # raise Interrupt, nil # let the run loop catch it
      run_suite
    end
  end

  run_suite
end
