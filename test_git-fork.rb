#!/usr/bin/env ruby

$:.unshift(__dir__)
# require is not properly loading this file. using load insead
load 'git-fork'
require "minitest/autorun"

class TestGitFork < Minitest::Test
  REPO_NAME     = "rails"
  ORIGIN_NAME   = "kbrock"
  UPSTREAM_NAME = "rails"
  ORIGIN_URL    = "git@github.com:#{ORIGIN_NAME}/#{REPO_NAME}.git"
  UPSTREAM_URL  = "git@github.com:#{UPSTREAM_NAME}/#{REPO_NAME}.git"
  UPSTREAM_HTTP = "https://github.com/#{UPSTREAM_NAME}/#{REPO_NAME}"
  PARAMS = [REPO_NAME, ORIGIN_URL, UPSTREAM_URL]

  def setup
    @fork = GitFork.new
    @fork.user = ORIGIN_NAME
  end

  # parse_params

  def test_two_urls
    assert_equal PARAMS, @fork.parse_params(ORIGIN_URL, UPSTREAM_URL)
  end

  def test_two_wrong_order
    assert_equal PARAMS, @fork.parse_params(UPSTREAM_URL, ORIGIN_URL)
  end

  def test_rails
    assert_equal PARAMS, @fork.parse_params(REPO_NAME)
  end

  def test_rails_rails
    assert_equal PARAMS, @fork.parse_params("#{UPSTREAM_NAME}/#{REPO_NAME}")
  end

  def test_rails_rails_url
    assert_equal PARAMS, @fork.parse_params(UPSTREAM_URL)
  end

  def test_rails_rails_http
    assert_equal PARAMS, @fork.parse_params(UPSTREAM_HTTP)
  end

  ## def test_kbrock_rails
  ## end

  ## def test_kbrock_rails_url
  ## end
end
