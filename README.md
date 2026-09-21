# kuberails

> Kubernetes API / CRD convention layer for Rails applications.

Rails アプリが Kubernetes API・CRD を扱う際の**接続・CRD アクセス・障害処理の規約層**を
gem として提供します。

[![Test](https://github.com/doridoridoriand/kuberails/actions/workflows/test.yml/badge.svg)](https://github.com/doridoridoriand/kuberails/actions/workflows/test.yml)
[![Gem Version](https://badge.fury.io/rb/kuberails.svg)](https://rubygems.org/gems/kuberails)

詳細な設計思想は [設計書 (docs/design.md)](docs/design.md)（KBR-DESIGN-001）に載せています。

## 前提条件

| 項目 | 対応範囲 | 備考 |
|------|---------|------|
| Ruby | `>= 3.3, < 4.0` | 下限: kruby 1.36.x が Ruby 3.3 を要求。上限: 未検証の Ruby 4.x を宣言から除外。CI は 3.3.0 / 3.3.8 / 3.4.10 の matrix で宣言範囲を検証 |
| kruby | `~> 1.36.0` | 公式 Kubernetes OpenAPI クライアント |
| Kubernetes サーバ | **v1.33.x で検証済み**（実クラスタ microk8s v1.33.13、2026-09-21） | kruby 1.36.x は 1.36 系のクライアント。より新しいサーバ（1.36 等）でも同じ API（CustomObjects API v1）を使うため互換性は期待できるが、まだ実機検証はしていない |
| 依存 | 実行時 **kruby のみ** | ActiveSupport は計測（[計測](#計測activessupport-任意)）にだけ任意で使う（無い環境は no-op） |

## インストール

```ruby
# Gemfile
gem "kuberails", "~> 0.1"
```

```ruby
require "kuberails"
KubeRails::VERSION # => "0.1.0"
```

`require` 自体は副作用なし・クラスタ不要です。kruby 本体は `KubeRails.client` /
`KubeRails.connected?` / CRD 操作の初回呼び出しの**lazy connect** で require されるため、
クラスタが接続できていなくても gem はロードできます。

## クイックスタート

```ruby
# config/initializers/kuberails.rb
KubeRails.configure do |config|
  config.namespace = "team-a" # デフォルト namespace（宣言・呼び出しで上書き可）
end

# 扱う CRD を宣言（group / version / plural / kind は推測しないため必ず指定）
Workflow = KubeRails.crd(
  group:  "argoproj.io",
  version: "v1alpha1",
  plural: "workflows",
  kind:   "Workflow",
  readonly: false, # 既定 true。false で create/patch 有効化
)
```

```ruby
Workflow.list                 # => [{"name" => "...", "labels" => {...}}, ...]
Workflow.find("wf-1")         # 同型 / 存在しなければ KubeRails::NotFound
Workflow.find_or_nil("wf-1")  # 同上、NotFound 時は nil
Workflow.create({ metadata: { name: "wf-1" } })                     # readonly: false のみ
Workflow.patch("wf-1", [{ op: "replace", path: "/spec/a", value: 2 }]) # 同左

KubeRails.connected?          # 成功時は true。失敗は例外を raise
```

## 設定

```ruby
KubeRails.configure do |config|
  config.namespace = "team-a"          # デフォルト namespace（既定 "default"）
  # config.connection = my_config      # Kubernetes::Configuration を直接渡す（任意）
  # config.instrumentation = false     # 計測を無効化（既定 true。ActiveSupport 存在時のみ有効）
  # config.api_client = stub           # テスト専用: transport を注入（[テスト](#テスト)）
end
```

- `configure` は**1 回だけ**有効です。2 回目の呼び出しは warn して無視されます
  （再設定が必要な場合は `KubeRails.reset!` — テスト支援）
- 接続の解決順: `config.api_client`（テスト注入）→ `config.connection` →
  `Kubernetes::Configuration.default_config`（in-cluster → KUBECONFIG の自動検出）

## CRD 宣言とアクセス

`plural` / `kind` は**推測しません**（推測が外れる CRD が多い）。
同名の再宣言は `KubeRails::RedeclarationError`（設定ミスの検出）を raise します。

戻り値は**常に文字列キーの Hash** です（kruby はシンボルキーを返すが、
Rails 側 JSON/ビューは文字列キーで扱うため、gem 内部の純 Ruby 変換で統一。
ActiveSupport に非依存）。各メソッドは `namespace:` 引数を受け取り、
宣言時の namespace を上書きできます。

`readonly` は**明示的な boolean**（`nil` 等は `ArgumentError`）。
書き込み有効化は `readonly: false` のみで、誤って fail-open になることはありません。

## 接続確認

```ruby
KubeRails.connected?  # 成功時は true。失敗は KubeRails::Unavailable / ApiError を raise
                      # /version 相当の軽量確認
```

`false` を返す経路はありません — 接続不能は例外として上がります（`rescue` で扱う）。
実際の API 接続は lazy で、初回 API 呼び出し時に確立されます。

## 例外体系

```
KubeRails::Error < StandardError
├── KubeRails::Unavailable   # 転送層失敗（DNS/タイムアウト/接続拒否。kruby 1.36.x では ApiError code 0）
├── KubeRails::NotFound      # HTTP 404
├── KubeRails::ApiError      # その他の API エラー（401/403/409/422/5xx）。#code と #response を保持
├── KubeRails::ReadOnlyError      # readonly: true 宣言で create/patch を呼ばれた
└── KubeRails::RedeclarationError # 同名 CRD の再宣言
```

呼び出し側の推奨パターン:

```ruby
begin
  Workflow.list
rescue KubeRails::Unavailable
  # クラスタ起因 → 「取得不能」フォールバック表示等
rescue KubeRails::ApiError => e
  # e.code / e.response で原因を判定
end
```

## 計測（ActiveSupport 任意）

`config.instrumentation = true`（既定）かつ ActiveSupport がロード済みのとき、
各 API 呼び出しを `kuberails.request` notification で計測します（無い環境は no-op）:

```
kuberails.request
  payload: { operation:, group:, version:, plural:, namespace:, duration_ms:,
             status: "ok" | "unavailable" | "api_error" }
```

Rails アプリでは `ActiveSupport::Notifications` で拾えます:

```ruby
ActiveSupport::Notifications.subscribe("kuberails.request") do |name, start, finish, id, payload|
  Rails.logger.info("[kuberails] #{payload[:operation]} #{payload[:plural]} (#{payload[:duration_ms]}ms) #{payload[:status]}")
end
```

## テスト

テストは**クラスタ不要**です。`config.api_client` に transport のスタブを
注入して行います。注入先は内部で適応層に包まれるため、スタブは kruby の
`CustomObjectsApi` と同型の 4 メソッドを実装します:

```ruby
class StubTransport
  def list_namespaced_custom_object(group, version, namespace, plural) = { items: [] }
  def get_namespaced_custom_object(group, version, namespace, plural, name) = {}
  def create_namespaced_custom_object(group, version, namespace, plural, body) = {}
  def patch_namespaced_custom_object(group, version, namespace, plural, name, body) = {}
end

KubeRails.configure { |c| c.api_client = StubTransport.new }
```

## 開発

```
bundle install
bundle exec rake   # rspec + rubocop
```

## 既知の注意点: kruby 1.36 の Bearer トークンキー不一致

kruby 1.36.x の in-cluster / KUBECONFIG 設定が Bearer トークンを
`api_key['authorization']` に書きますが、`Configuration#auth_settings` が
`Authorization` ヘッダに読むのは `api_key['BearerToken']` です。キーがずれているため
**そのままでは Authorization ヘッダが空になり 401** になります。

kuberails は `Client.build` 時に `authorization` を `BearerToken` に複製する
処理（設計書では「K1 橋渡し」と呼称）を自動で行います（`BearerToken` が既に
設定されていれば上書きしません）。このため kuberails 経由で接続する場合は
この問題の影響を受けません。kruby 本体の挙動（gem の外側）に依存する
クラスタ接続で 401 が出たら、まずこのトークンキーの問題を確認してください。

## 今後の予定（v0.2+）

- Ruby 3.5 / 4.0 の対応（stable 化の検証の上、宣言範囲と CI matrix に追加）
- kind を使った E2E テストの CI 化
- watch（ストリーム処理）の導入検討

## License

MIT（[LICENSE](LICENSE)）
