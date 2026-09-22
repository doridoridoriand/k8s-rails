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
  # 上限 `< 4.1` は「宣言した minor を必ず CI で検証する」方針のため:
  # 2026-09-22 に Ruby 4.0.7（stable）と Ruby 3.5.0-preview1（3.5 系で公開済みの
  # 唯一のリリース・ruby/ruby タグ実測）で全 suite / rubocop を実行し緑を確認
  # （matrix に 4.0.7 / 3.5.0-preview1 を追加）。この範囲で公開済みの Ruby は
  # 3.3.x / 3.4.x / 3.5.0-preview1 / 4.0.x のみ（4.1 系のリリースなし・
  # 実測 2026-09-22）のため宣言範囲 = 検証範囲が成立。RubyGems の version
  # requirement は集合和（union）を表現できないため、未検証 minor を区間で
  # 挟み込む形（`< 5.0` 等）は取らない。
  spec.required_ruby_version = [">= 3.3", "< 4.1"]

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
