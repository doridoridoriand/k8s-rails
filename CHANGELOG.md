# Change Log

`kuberails` の全 notable な変更はこのファイルに記録する。

## 0.1.0

- **M0**: gem 骨子（gemspec / Gemfile / Rakefile / version / require 構造）
- **M1**: Configuration + Client（lazy connect・K1 BearerToken 橋渡し）・例外体系
  （`Unavailable` / `NotFound` / `ApiError` + `ReadOnlyError` / `RedeclarationError`）
- **M2**: CRD 宣言 DSL + Resource（`list` / `find` / `find_or_nil` / `create` / `patch`、
  `readonly` は明示 boolean、再宣言は `RedeclarationError`）
- **M3**: 計測（ActiveSupport::Notifications 経由、無効時 no-op）+ README + rubocop
- **M4**: consumer app の `consumer app 側の K8s service` 移行で動作検証
  （実クラスタ microk8s v1.33.13、kuberails#6 / consumer app#63）
- 応答は常に文字列キー（K2）・純 Ruby `Normalizer`（ActiveSupport 非依存）
- 対応 Ruby: `>= 3.3, < 4.0`（下限は kruby 1.36.x の `>= 3.3`。上限は
  未検証の Ruby 4.x を宣言から除外するため。4.0 / 3.5 対応は v0.2 以降
  で検証の上宣言に含める）。
  CI（GitHub Actions）で 3.3.0 / 3.3.8 / 3.4.10 の matrix 検証
- 対応 Kubernetes サーバ: v1.33.x で実クラスタ検証済み（README 参照）
- 公開導線: GitHub Actions（push / PR で rspec + rubocop、タグ `v*` で
  `gem build` + `gem push`）
