# typed: true
# frozen_string_literal: true

require "cli/parser"
require "csv"

module Homebrew
  extend T::Sig

  module_function

  PRIMARY_REPOS = %w[brew core cask].freeze
  SUPPORTED_REPOS = [
    PRIMARY_REPOS,
    OFFICIAL_CMD_TAPS.keys.map { |t| t.delete_prefix("homebrew/") },
    OFFICIAL_CASK_TAPS.reject { |t| t == "cask" },
  ].flatten.freeze

  sig { returns(CLI::Parser) }
  def contributions_args
    Homebrew::CLI::Parser.new do
      usage_banner "`contributions` <email|username> [<--repositories>`=`] [<--csv>]"
      description <<~EOS
        Contributions to Homebrew repos for a user.

        The first argument is a GitHub username (e.g. "BrewTestBot") or an email address (e.g. "brewtestbot@brew.sh").
      EOS

      comma_array "--repositories",
                  description: "Specify a comma-separated (no spaces) list of repositories to search. " \
                               "Supported repositories: #{SUPPORTED_REPOS.map { |t| "`#{t}`" }.to_sentence}. " \
                               "Omitting this flag, or specifying `--repositories=all`, searches all repositories. " \
                               "Use `--repositories=primary` to search only the main repositories: brew,core,cask."
      flag "--from=",
           description: "Date (ISO-8601 format) to start searching contributions."

      flag "--to=",
           description: "Date (ISO-8601 format) to stop searching contributions."

      switch "--csv",
             description: "Print a CSV of a user's contributions across repositories over the time period."

      named_args number: 1
    end
  end

  sig { void }
  def contributions
    args = contributions_args.parse

    results = {}

    all_repos = args.repositories.nil? || args.repositories.include?("all")
    repos = if all_repos
      SUPPORTED_REPOS
    elsif args.repositories.include?("primary")
      PRIMARY_REPOS
    else
      args.repositories
    end

    repos.each do |repo|
      if SUPPORTED_REPOS.exclude?(repo)
        return ofail "Unsupported repository: #{repo}. Try one of #{SUPPORTED_REPOS.join(", ")}."
      end

      repo_path = find_repo_path_for_repo(repo)
      tap = Tap.fetch("homebrew", repo)
      unless repo_path.exist?
        opoo "Repository #{repo} not yet tapped! Tapping it now..."
        tap.install
      end

      repo_full_name = if repo == "brew"
        "homebrew/brew"
      else
        tap.full_name
      end

      results[repo] = {
        commits:       GitHub.repo_commit_count_for_user(repo_full_name, args.named.first),
        coauthorships: git_log_trailers_cmd(T.must(repo_path), "Co-authored-by", args),
        signoffs:      git_log_trailers_cmd(T.must(repo_path), "Signed-off-by", args),
      }
    end

    puts "The user #{args.named.first} has made #{total(results)} contributions #{time_period(args)}."
    puts generate_csv(args.named.first, results) if args.csv?
  end

  sig { params(repo: String).returns(Pathname) }
  def find_repo_path_for_repo(repo)
    return HOMEBREW_REPOSITORY if repo == "brew"

    Tap.fetch("homebrew", repo).path
  end

  sig { params(args: Homebrew::CLI::Args).returns(String) }
  def time_period(args)
    if args.from && args.to
      "between #{args.from} and #{args.to}"
    elsif args.from
      "after #{args.from}"
    elsif args.to
      "before #{args.to}"
    else
      "in all time"
    end
  end

  sig { params(user: String, results: Hash).returns(String) }
  def generate_csv(user, results)
    CSV.generate do |csv|
      csv << %w[user repo commits coauthorships signoffs total]
      results.each do |repo, counts|
        csv << [
          user,
          repo,
          counts[:commits],
          counts[:coauthorships],
          counts[:signoffs],
          counts.values.sum,
        ]
      end
      csv << [user, "*", "*", "*", "*", total(results)]
    end
  end

  sig { params(results: Hash).returns(Integer) }
  def total(results)
    results
      .values # [{:commits=>1, :coauthorships=>0, :signoffs=>3}, {:commits=>500, :coauthorships=>2, :signoffs=>450}]
      .map(&:values) # [[1, 0, 3], [500, 2, 450]]
      .sum(&:sum) # 956
  end

  sig { params(repo_path: Pathname, trailer: String, args: Homebrew::CLI::Args).returns(Integer) }
  def git_log_trailers_cmd(repo_path, trailer, args)
    cmd = ["git", "-C", repo_path, "log", "--oneline"]
    cmd << "--format='%(trailers:key=#{trailer}:)'"
    cmd << "--before=#{args.to}" if args.to
    cmd << "--after=#{args.from}" if args.from

    Utils.safe_popen_read(*cmd).lines.count { |l| l.include?(args.named.first) }
  end
end
