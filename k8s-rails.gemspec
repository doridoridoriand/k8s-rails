# frozen_string_literal: true

require_relative "lib/k8s_rails/version"

Gem::Specification.new do |spec|
  spec.name = "k8s-rails"
  spec.version = K8sRails::VERSION
  spec.authors = ["Dorian - Takahiro Ishida"]
  spec.email = ["i.am.eager.for.peace@gmail.com"]

  spec.summary = "Kubernetes API / CRD convention layer for Rails applications"
  spec.description =
    "k8s-rails provides the connection / CRD access / error-handling " \
    "convention layer for Rails applications talking to the Kubernetes API, as a gem."
  spec.homepage = "https://github.com/doridoridoriand/k8s-rails"
  spec.license = "MIT"
  # kruby 1.36.x は required_ruby_version ">= 3.3"（RubyGems API で実測 2026-09-21、
  # 1.36.0.1〜1.36.4.1 全バージョン）。実行時依存の下限に合わせる。
  # 上限 `< 4.0` は「宣言した minor を必ず CI で検証する」方針のため（レビュー対応・
  # 2026-09-21）: 2026-09-21 時点で Ruby 3.5 は preview（ruby/ruby タグ
  # v3_5_0_preview1）、4.0 は stable（v4.0.7）。未検証の 4.x を宣言範囲から
  # 除外し、4.0 対応検証は v0.3 で行う（設計書 §10）。
  spec.required_ruby_version = [">= 3.3", "< 4.0"]

  # RubyGems.org ページに source / changelog リンクを表示させるためのメタ情報。
  spec.metadata["source_code_uri"] = "https://github.com/doridoridoriand/k8s-rails"
  spec.metadata["changelog_uri"] = "https://github.com/doridoridoriand/k8s-rails/blob/main/CHANGELOG.md"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE", "CHANGELOG.md", "docs/design.md"]
  spec.require_paths = ["lib"]

  # kruby (official Kubernetes OpenAPI client). Pinned to the 1.36.x line;
  # see docs/design.md §6 (why ~> 1.36.0, not ~> 1.36).
  spec.add_dependency "kruby", "~> 1.36.0"

  # Optional at runtime (guarded via defined?(ActiveSupport::Notifications) in §8).
  # Development dependency so specs can exercise the instrumentation path.
  spec.add_development_dependency "activesupport", ">= 7.0"
  spec.add_development_dependency "rake", ">= 13.0"
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rubocop", ">= 1.60"
end
