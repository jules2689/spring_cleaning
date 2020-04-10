require "octokit"
require "cli/ui"

class GithubClient
  RetryError = Class.new(StandardError)
  VERSION = "v1"
  REPOS_CACHE_PATH = File.expand_path("../data/repos_#{VERSION}.json", __FILE__)
  attr_reader :github_client

  def initialize(token)
    @github_client = Octokit::Client.new(access_token: token)
    @github_client.auto_paginate = true
  end

  def close_all_issues(repo, success = ->() {}, failure = ->(err) {})
    unless CLI::UI.confirm("Are you sure you want to {{red:close all issues}} this repo?")
      raise RetryError
    end

    issues = @github_client.list_issues(repo).reject { |i| !i.pull_request.nil? }
    puts "Found #{issues.size} issues for #{repo}"

    spin_group = CLI::UI::SpinGroup.new
    issues.each do |issue|
      spin_group.add("Closing [##{issue.number}] #{issue.title}") do
        @github_client.close_issue(repo, issue.number)
      end
    end
    spin_group.wait
    success.call()
    issues.map(&:id)
  rescue => e
    failure.call(e)
  end

  def find_all_repos
    # Load cache if it exists and is valid
    repos_cache = begin
      JSON.parse(File.read(REPOS_CACHE_PATH))
    rescue JSON::ParserError, Errno::ENOENT
      {}
    end

    # If we're still empty (cache was empty, or invalid) then fetch al the repos
    if repos_cache.empty?
      repos = []
      CLI::UI::Spinner.spin("Calling out to GitHub, this could take a while if you have access to a lot of repos") do |spinner|
        repos = @github_client.repositories
      end
      repos_cache = repos.each_with_object({}) do |r, acc|
        acc[r.owner.login] ||= {}
        acc[r.owner.login][r.id] = {
          name: r.name,
          fork: r.fork,
          archived: r.archived,
          private: r.private,
          url: r.html_url,
          stars: r.stargazers_count,
          subscribers: r.subscribers_count,
          open_issues_count: r.open_issues_count,
          last_push: r.pushed_at,
          last_update: r.updated_at,
        }
      end
      File.write(REPOS_CACHE_PATH, JSON.pretty_generate(repos_cache))
    end

    repos_cache
  end

  def archive_repo(org, name, success = ->() {}, failure = ->(err) {})
    unless CLI::UI.confirm("Are you sure you want to archive this repo?")
      raise RetryError
    end
  
    @github_client.update_repository("#{org}/#{name}", archived: true)
    if @github_client.last_response.status < 300
      success.call()
    else
      failure.call()
    end
  rescue Octokit::Error => e
    if e.is_a?(Octokit::Forbidden) && e.message =~ /was archived/
      success.call()
    else
      failure.call(e)
    end
  end
  
  def delete_repo(org, name, success = ->() {}, failure = ->(err) {})
    unless CLI::UI.confirm("Are you sure you want to {{red:delete}} this repo? This {{bold:cannot be undone}}")
      raise RetryError
    end
  
    if @github_client.delete_repo("#{org}/#{name}")
      success.call()
    else
      failure.call()
    end
  rescue Octokit::Error => e
    failure.call(e)
  end
end