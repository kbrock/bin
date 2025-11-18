#!/usr/bin/env ruby
# frozen_string_literal: true

require 'octokit'
require 'json'

class GitHubContributionCounter
  def initialize(username, access_token = nil)
    @username = username
    @client = Octokit::Client.new(access_token: access_token || ENV['GITHUB_TOKEN'])
    @client.auto_paginate = false
    @repos = Hash.new(0) # repo_name => merged_pr_count
  end

  def count_repos_graphql
    puts "Fetching merged pull requests for #{@username} using GraphQL API..."

    cursor = nil
    page = 0
    total_prs = 0

    loop do
      page += 1
      check_rate_limit

      query = build_graphql_query(cursor)
      result = @client.post('/graphql', { query: query }.to_json)

      # Check for errors
      if result[:errors]
        puts "GraphQL errors: #{result[:errors]}"
        raise "GraphQL query failed"
      end

      user_data = result[:data][:user]
      unless user_data
        puts "Error: User '#{@username}' not found"
        return 0
      end

      prs_connection = user_data[:pullRequests]
      prs_data = prs_connection[:nodes]

      prs_data.each do |pr|
        repo_full_name = "#{pr[:repository][:owner][:login]}/#{pr[:repository][:name]}"
        @repos[repo_full_name] += 1
        total_prs += 1
      end

      puts "Page #{page}: Processed #{prs_data.length} merged PRs (Total PRs: #{total_prs}, Unique repos: #{@repos.size})"

      page_info = prs_connection[:pageInfo]
      break unless page_info[:hasNextPage]

      cursor = page_info[:endCursor]
    end

    @repos.size
  end

  def display_results
    # Partition repositories into ManageIQ and non-ManageIQ
    # would be nice to prune out forks of user/miq libraries.
    my_repos = /(manageiq|miq|#{@username})/i
    manageiq_repos = @repos.select { |repo, _count| repo =~ my_repos }
    other_repos = @repos.reject { |repo, _count| repo =~ my_repos }

    # Display both categories
    display_category("ManageIQ Repositories", manageiq_repos)
    display_category("Other Repositories", other_repos)

    # Display grand total
    puts "\n" + "=" * 80
    total_repos = @repos.size
    total_prs = @repos.values.sum
    puts "GRAND TOTAL: #{total_repos} repositories, #{total_prs} merged pull requests"
    puts "=" * 80
  end

  private

  def display_category(title, repos_hash)
    sorted_repos = repos_hash.sort_by { |repo, count| [-count, repo] }
    total_prs = repos_hash.values.sum

    puts "\n" + "=" * 80
    puts "#{title} (#{sorted_repos.size} repositories)"
    puts "=" * 80
    printf("%-60s %s\n", "Repository", "Merged PRs")
    puts "-" * 80

    sorted_repos.each do |repo, count|
      printf("%-60s %d\n", repo, count)
    end

    puts "-" * 80
    puts "#{title.split.first} Total: #{sorted_repos.size} repositories, #{total_prs} merged pull requests"
  end

  def build_graphql_query(cursor = nil)
    after_clause = cursor ? ", after: \"#{cursor}\"" : ""

    <<~GRAPHQL
      query {
        user(login: "#{@username}") {
          pullRequests(
            first: 100#{after_clause}
            states: [MERGED]
            orderBy: {field: CREATED_AT, direction: ASC}
          ) {
            pageInfo {
              hasNextPage
              endCursor
            }
            nodes {
              repository {
                name
                owner {
                  login
                }
              }
            }
          }
        }
      }
    GRAPHQL
  end

  def check_rate_limit
    rate_limit = @client.rate_limit
    remaining = rate_limit.remaining

    if remaining < 10
      reset_time = rate_limit.resets_at
      sleep_time = (reset_time - Time.now).to_i + 5

      if sleep_time > 0
        puts "\nRate limit nearly exceeded (#{remaining} requests remaining)"
        puts "Sleeping for #{sleep_time} seconds until #{reset_time}..."
        sleep(sleep_time)
      end
    elsif remaining < 100 && remaining % 10 == 0
      puts "Rate limit: #{remaining} requests remaining"
    end
  end
end

# Main execution
if __FILE__ == $PROGRAM_NAME
  username = ARGV[0] || 'kbrock'
  access_token = ENV['GITHUB_TOKEN']

  unless access_token
    puts "Error: GITHUB_TOKEN environment variable not set."
    puts "Set it with: export GITHUB_TOKEN='your_token'"
    puts "Create a token at: https://github.com/settings/tokens"
    exit 1
  end

  counter = GitHubContributionCounter.new(username, access_token)

  puts "=" * 80
  puts "GitHub Merged Pull Request Counter"
  puts "=" * 80
  puts ""

  counter.count_repos_graphql
  counter.display_results
end
