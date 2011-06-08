#!/usr/bin/env ruby

#require 'rubygems'
require 'grit'

# remove branch references that are stored locally but have been removed from the server
`git remote prune origin`

MASTER = 'origin/master'

repo = Grit::Repo.new('.')

puts "branch, last committer, last commit date, merged into master, number of diff commits"

repo.remotes.each do |b|
  next if b.name == MASTER || b.name == "origin/HEAD"
  branch_name = b.name.split('/').last #remove 'origin/ for display'
  last_commit = repo.commits(b.name, 1).first
  commit_diff = repo.commits_between(MASTER,b.name)
  commit_date = last_commit.date.strftime('%Y-%m-%d')
  puts "#{branch_name}, #{last_commit.committer.name}, #{commit_date}, #{commit_diff.empty?}, #{commit_diff.size}"
end
