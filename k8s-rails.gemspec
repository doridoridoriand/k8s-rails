# frozen_string_literal: true

require_relative "lib/k8s_rails/version"

Gem::Specification.new do |spec|
  spec.name = "k8s-rails"
  spec.version = K8sRails::VERSION
  spec.authors = ["Dorian - Takahiro Ishida"]
  spec.email = ["i.am.eager.for.peace@gmail.com"]

  spec.summary = "Kubernetes API access convention layer for Rails applications"
  spec.description =
    "k8s-rails provides the connection, resource access, and error-handling " \
    "convention layer for Rails applications talking to the Kubernetes API, as a gem."
  spec.homepage = "https://github.com/doridoridoriand/k8s-rails"
  spec.license = "MIT"
  # kruby 1.36.x は required_ruby_version ">= 3.3"（RubyGems API で実測
  # 2026-10-18、1.36.0.1〜1.36.5.2 全バージョン）。実行時依存の下限に合わせる。
  # 上限 `< 4.1` は「宣言した minor を必ず CI で検証する」方針のため:
  # 2026-09-22 に Ruby 4.0.7（stable）と Ruby 3.5.0-preview1（3.5 系で公開済みの
  # 唯一のリリース・ruby/ruby タグ実測）で全 suite / rubocop を実行し緑を確認
  # （matrix に 4.0.7 / 3.5.0-preview1 を追加）。kruby 1.36.5.2（2026-10-17）でも
  # 3 系統を再実測（#41）。Ruby 4.1.0-preview1 は 2026-10-17 に ruby/ruby タグで
  # 公開済みで、Gem.ruby_version は prerelease 形式（実測: 4.1.0-preview1 →
  # `4.1.0.preview1`）を報告するため `< 4.1` では除外されない（実測: 許容される）。
  # そこで `!= 4.1.0.preview1` で**その 1 バージョンのみを除外**する（PR #42
  # レビュー指摘・`Gem::Requirement` の conjunctive `!=` で実現 — 集合和は不要。
  # 実測: 4.1.0.preview1 = 不許可 / 4.0.7・3.5.0.preview1 = 許可 / 4.1 = 不許可）。
  # 4.1.0-preview1 を matrix に入れられない理由（実測 2026-10-17・ローカル
  # rbenv 4.1.0-preview1）: `bundle install` が RubyGems/Bundler 既知の
  # `uninitialized constant Pathname::SEPARATOR_PAT`（Bundler 4.0.23 でも再現）
  # で失敗し、Bundler 依存の検証基盤自体が動かない。
  # 注意: `!=` は名指した 1 バージョンのみ除外する。将来の preview
  # （4.1.0.preview2 等）は再び区間内に現れるため、その都度 `!=` を追加するか
  # 4.1 stable リリース時に上限を `< 4.2` に上げて matrix 追加で検証する。
  spec.required_ruby_version = [">= 3.3", "< 4.1", "!= 4.1.0.preview1"]

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
