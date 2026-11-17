# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubocop/rake_task"

RSpec::Core::RakeTask.new(:spec)

RuboCop::RakeTask.new(:rubocop)

desc "Run the kind-cluster E2E suite (requires a kind-* kubectl context; see scripts/e2e_kind.rb)"
task :e2e do
  sh "bundle exec ruby scripts/e2e_kind.rb"
end

task default: %i[spec rubocop]
