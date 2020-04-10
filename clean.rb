require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "octokit", "4.18.0"
  gem "cli-ui", "1.3.0"
  gem "dotenv"
end

require "dotenv"
require "cli/ui"
require_relative "github_client"
require "json"

def success_callback(action = nil)
  -> () do
    puts CLI::UI.fmt("{{v}} Success.")
    CURRENT_DECISIONS[org]['repos'][name][action] = true if action
  end
end

def failure_callback
  -> (err) do
    puts CLI::UI.fmt("{{?}} Failed. #{err.message}")
  end
end

def can_skip?(repo)
  repo['archived'] || repo['skipped'] || repo['deleted']
end

def process_all_repos(org, repos)
  repos.each do |id, name|
    CURRENT_DECISIONS[org]['repos'][name] ||= {}
    next if can_skip?(CURRENT_DECISIONS[org]['repos'][name])

    CURRENT_DECISIONS[org]['repos'][name]['decisions'] ||= []

    CLI::UI::Frame.open(name, timing: false) do
      begin
        CLI::UI::Prompt.ask('What do you want to do?') do |handler|
          handler.option('Archive') do
            CURRENT_DECISIONS[org]['repos'][name]['decisions'] << { action: 'Archive', time: Time.now }
            GITHUB_CLIENT.archive_repo(org, name, success_callback("archive"), failure_callback)
          end
          handler.option('Delete') do
            CURRENT_DECISIONS[org]['repos'][name]['decisions'] << { action: 'Delete', time: Time.now }
            GITHUB_CLIENT.delete_repo(org, name, success_callback("delete"), failure_callback)
          end
          handler.option('Close all issues') do
            CURRENT_DECISIONS[org]['repos'][name]['decisions'] << { action: 'Close Issues', time: Time.now }
            GITHUB_CLIENT.close_all_issues("#{org}/#{name}", success_callback(), failure_callback)
            raise GithubClient::RetryError # Always wanna retry as we haven't skipped, archived, or deleted
          end
          handler.option('Open') do
            system("open https://github.com/#{org}/#{name}")
            raise GithubClient::RetryError
          end
          handler.option('Skip') do
            CURRENT_DECISIONS[org]['repos'][name]['decisions'] << { action: 'Skip Issues', time: Time.now }
            CURRENT_DECISIONS[org]['repos'][name]['skipped'] = true
          end
        end
      rescue GithubClient::RetryError
        retry
      end
    end
  end
end

def process_all_orgs(cache)
  CLI::UI::Frame.open("Processing by owner...") do
    cache.each do |org, repos|
      CURRENT_DECISIONS[org] ||= { 'repos' => {} }

      if CURRENT_DECISIONS[org]['skipped']
        puts CLI::UI.fmt "{{i}} {{cyan:#{org}}} is marked as skipped in the decision log, skipping."
        next
      end

      # Can skip if we have handled all the repos and all are skippable
      if repos.values.all? { |name| CURRENT_DECISIONS[org]['repos'].key?(name) } && CURRENT_DECISIONS[org]['repos'].all? { |_, v| can_skip?(v) }
        puts CLI::UI.fmt "{{i}} All repos in {{cyan:#{org}}} are marked as skipped, deleted, or archived in the decision log, skipping this org."
        next
      end

      CURRENT_DECISIONS[org]['decisions'] ||= []

      CLI::UI::Frame.open(org, timing: false) do
        unless CLI::UI.confirm("Do you want to process #{repos.size} repo(s) in #{org}?")
          CURRENT_DECISIONS[org]['skipped'] = true
          CURRENT_DECISIONS[org]['decisions'] << { name: 'Skipped', time: Time.now }
          next
        end

        CURRENT_DECISIONS[org]['decisions'] << { name: 'Process', time: Time.now }
        process_all_repos(org, repos)
      end
    end
  end
end

def ask_for_token
  CLI::UI::Frame.open("Could not find GitHub Token", color: :red) do
    puts CLI::UI.fmt "We could not find your token stored in the {{command:.env}} file."
    puts CLI::UI.fmt "Please go to {{cyan:{{underline:https://github.com/settings/tokens}}}} and"
    puts CLI::UI.fmt "generate a token with {{underline:repo}} and {{underline:delete_repo}} scopes"
    CLI::UI::Frame.divider(nil)
    puts CLI::UI.fmt "We are asking you for your token to store in the gitignored {{command:.env}} file"
    puts CLI::UI.fmt "If you don't want to give it here, please put it in {{command:.env}} yourself as {{command:TOKEN=<token>}}"
    token = CLI::UI.ask("What is your token?")

    # Write to file and reload
    f = File.open(File.expand_path("../.env", __FILE__), "a")
    f.write("TOKEN=#{token}")
    f.close
    Dotenv.load
  end
end

# Library Setup
CLI::UI::StdoutRouter.enable

Dotenv.load
ask_for_token if ENV['TOKEN'].nil?

GITHUB_CLIENT = GithubClient.new(ENV["TOKEN"])
DECISIONS_CACHE_PATH = File.expand_path("../data/decisions.json", __FILE__)
CURRENT_DECISIONS = begin
  JSON.parse(File.read(DECISIONS_CACHE_PATH))
rescue JSON::ParserError, Errno::ENOENT
  {}
end

repos_cache = {}
begin
  CLI::UI::Frame.open("Getting Started", timing: false) do
    puts "This script will walk you through all repositories to which you have access"
    puts "It will help you audit them, archiving or deleting ones you no longer want"
    puts ""
    CLI::UI::Frame.divider('Tips')
    puts CLI::UI.fmt "{{i}} {{italic:Yes/No}} questions can be answered with {{command:y}} and {{command:n}} keys"
    puts CLI::UI.fmt "{{i}} {{italic:Numbered questions}} can be answered with the {{command:number}} keys"
    puts CLI::UI.fmt "{{i}} You can move {{italic:up and down}} the questions with {{command:arrow keys}} or {{command:vim bindings}}, press {{command:enter}} to {{italic:select}}"
    puts CLI::UI.fmt "{{i}} Press {{command:Ctrl-C}} at any time after the repos load to save your progress"
    puts ""
    CLI::UI::Frame.divider('Ready?')
    unless CLI::UI.confirm("Are you ready to get started?")
      exit 0
    end
  end

  CLI::UI::Frame.open("Finding Repos") do
    repos_cache = GITHUB_CLIENT.find_all_repos
    repos_size = repos_cache.values.map(&:size).inject(:+)
    puts "Found #{repos_size} repos across #{repos_cache.size} owners"
    puts CLI::UI.fmt "{{i}} You can now press {{command:Ctrl-C}} at any time to save your progress"
  end
rescue Interrupt
  puts CLI::UI.fmt "{{v}} Ok, nothing to save yet, bye!"
  exit 0
end

begin
  process_all_orgs(repos_cache)
rescue Interrupt
  puts CLI::UI.fmt "{{v}} Ok, saving your current decisions for later... bye!"
ensure
  File.write(DECISIONS_CACHE_PATH, JSON.pretty_generate(CURRENT_DECISIONS))
end
