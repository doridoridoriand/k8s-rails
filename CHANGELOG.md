# Change Log

`kuberails` の全 notable な変更はこのファイルに記録する。

## 0.1.0（リリース予定）

- **M0**: gem 骨子（gemspec / Gemfile / Rakefile / version / require 構造）
- **M1**: Configuration + Client（lazy connect・K1 BearerToken 橋渡し）・例外体系
  （`Unavailable` / `NotFound` / `ApiError` + `ReadOnlyError` / `RedeclarationError`）
- **M2**: CRD 宣言 DSL + Resource（`list` / `find` / `find_or_nil` / `create` / `patch`、
  `readonly` は明示 boolean、再宣言は `RedeclarationError`）
- **M3**: 計測（ActiveSupport::Notifications 経由、無効時 no-op）+ README + rubocop
- **M4**: consumer app の `consumer app 側の K8s service` 移行で動作検証
  （実クラスタ microk8s v1.33.13、kuberails#6 / consumer app#63）
- 応答は常に文字列キー（K2）・純 Ruby `Normalizer`（ActiveSupport 非依存）

## Unreleased

- リリース準備: README に検証済み Kubernetes サーババージョン（v1.33.x）を追記
- `CHANGELOG.md` 追加、gemspec に `source_code_uri` / `changelog_uri` メタ情報追加
- GitHub Actions 追加: push / PR 時に rspec + rubocop（テスト）、
  タグ `v*` push 時に `gem build` + `gem push`（RubyGems 公開）
