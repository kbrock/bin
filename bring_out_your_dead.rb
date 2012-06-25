#!/usr/bin/env ruby

# displays the git branches and their modification times
# usage: bring_out_your_dead.rb [-p] [path]
#   default a csv file with branch information
#   -p - display pretty instead of csv
#   path is the path to the repository / otherwise, assume it is the current directory

require 'rubygems'
require 'grit'

# remove branch references that are stored locally but have been removed from the server
`git remote prune origin`

MASTER = 'origin/master'


pretty=false
dir='.'
ARGV.each do |arg|
  if arg == '-p'
    pretty=true
  else
    dir = arg
  end
end

repo = Grit::Repo.new(dir)


puts "branch, last committer, last commit date, merged into master, number of diff commits" unless pretty

repo.remotes.sort_by do |b|
  last_commit = repo.commits(b.name, 1).first
  last_commit.nil? ? Time.now : last_commit.date
end.reverse.each do |b|
  next if b.name == MASTER || b.name == "origin/HEAD"
  branch_name = b.name.split('/').last #remove 'origin/ for display'
  last_commit = repo.commits(b.name, 1).first
  commit_diff = repo.commits_between(MASTER,b.name)
  commit_date = last_commit.date.strftime('%Y-%m-%d')
  if pretty
    puts "#{commit_date} #{commit_diff.empty? ? ' ' : '*'} #{branch_name}"
  elsif commit_diff || ! branch_name =~ /^\d{3}/
    puts "#{branch_name}, #{last_commit.committer.name}, #{commit_date}, #{commit_diff.empty?}, #{commit_diff.size}"
  end
end
