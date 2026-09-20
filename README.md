# kuberails

Rails アプリが Kubernetes API・CRD を扱う際の**接続・CRD アクセス・障害処理の規約層**を
gem として提供する。（設計書: [docs/design.md](docs/design.md), KBR-DESIGN-001）

- Ruby: `>= 3.2`（開発は 3.3.8、`.ruby-version` で pin）
- kruby: `~> 1.36.0`（公式 Kubernetes OpenAPI クライアント）
- 依存: 実行時 **kruby のみ**。ActiveSupport は計測（§8）にだけ任意で使う（無い環境は no-op）

```ruby
require "kuberails"
KubeRails::VERSION # => "0.1.0"
```

ロードは副作用なし。kruby 本体は `KubeRails.client` / `KubeRails.connected?` /
CRD 操作の初回呼び出しの**lazy connect** で require されるため、クラスタが
接続できていなくても gem はロードできます（§5.2）。

## 設定

```ruby
KubeRails.configure do |config|
  config.namespace = "team-a"          # デフォルト namespace（宣言・呼び出しで上書き可）
  # config.connection = my_config      # Kubernetes::Configuration を直接渡す（任意）
  # config.instrumentation = false     # §8 計測を無効化（既定 true。ActiveSupport 存在時のみ有効）
  # config.api_client = stub           # テスト専用: transport を注入（§5.1）
end
```

接続解決順（§5.2）: `config.api_client`（テスト注入）→ `config.connection` →
`Kubernetes::Configuration.default_config`（KUBECONFIG / in-cluster）。

## CRD 宣言とアクセス

`plural` / `kind` は**推測しない**（推測が外れる CRD が多い、K5）ので宣言で指定します。
同名再宣言は `KubeRails::RedeclarationError`（設定ミスの検出）。

```ruby
# config/initializers/kuberails_crd.rb
Workflow = KubeRails.crd(
  group:  "argoproj.io",
  version: "v1alpha1",
  plural: "workflows",
  kind:   "Workflow",
  namespace: KubeRails.config.namespace, # 省略可
  readonly: false,                       # 既定 true。false で create/patch 有効化（K4）
)

Workflow.list                     # => [{"name" => "...", "labels" => {...}}, ...] 文字列キー
Workflow.find("wf-1")             # 同型 / 存在しなければ KubeRails::NotFound
Workflow.find_or_nil("wf-1")      # 同上、NotFound 時は nil
Workflow.create({ metadata: { name: "wf-1" } })   # readonly: false のみ
Workflow.patch("wf-1", [{ op: "replace", path: "/spec/a", value: 2 }]) # 同左
```

- **戻り値は常に文字列キーの Hash**（K2）。ActiveSupport の `deep_stringify_keys`
  ではなく gem 内部の純 Ruby 変換（`KubeRails::Normalizer`）で行うため AS 非依存。
- 各メソッドは `namespace:` 引数を受け取り、宣言時の namespace を上書きできます。
- `readonly` は**明示的な boolean**（`nil` 等は `ArgumentError`）。書き込み有効化は
  `readonly: false` のみ（fail-open 防止）。

## 接続確認

```ruby
KubeRails.connected?  # 成功時は true。失敗は KubeRails::Unavailable / ApiError を raise
                      # /version 相当の軽量確認（VersionApi#get_code）
```

`false` を返す経路はありません — 接続不能は例外として上がります（`rescue` で扱う）。
`KubeRails::Client.build` は lazy で初回 API 呼び出し時に実際の接続が行われます。

## 例外体系（K3）

```ruby
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
rescue KubeRails::Unavailable => e
  # クラスタ起因 → ダッシュボード表示の「取得不能」フォールバック
rescue KubeRails::ApiError => e
  # e.code / e.response で原因を判定
end
```

## 計測（ActiveSupport 任意）

`config.instrumentation = true` かつ ActiveSupport がロード済みのとき、各 API 呼び出しを
`kuberails.request` notification で計測します（無い環境は no-op）:

```
kuberails.request
  payload: { operation:, group:, version:, plural:, namespace:, duration_ms:,
             status: "ok" | "unavailable" | "api_error" }
```

Rails アプリでは `ActiveSupport::Notifications` / `log_subscriptions` で拾えます:

```ruby
ActiveSupport::Notifications.subscribe("kuberails.request") do |name, start, finish, id, payload|
  Rails.logger.info("[kuberails] #{payload[:operation]} #{payload[:plural]} (#{payload[:duration_ms]}ms) #{payload[:status]}")
end
```

## 開発

```
bundle install
bundle exec rake   # rspec + rubocop
```

テストは**クラスタ不要**です。`config.api_client` に transport のスタブを
注入して行います（§9）。注入先は内部で `StringKeyedAdapter` に包まれるため、
スタブは kruby の `CustomObjectsApi` と同型の 4 メソッドを実装します:

```ruby
class StubTransport
  def list_namespaced_custom_object(group, version, namespace, plural) = { items: [] }
  def get_namespaced_custom_object(group, version, namespace, plural, name) = {}
  def create_namespaced_custom_object(group, version, namespace, plural, body) = {}
  def patch_namespaced_custom_object(group, version, namespace, plural, name, body) = {}
end

KubeRails.configure { |c| c.api_client = StubTransport.new }
```

## 設計メモ: kruby 1.36 の K1（トークンキー不一致）

kruby 1.36.x の in-cluster / KUBECONFIG 設定が Bearer トークンを
`api_key['authorization']` に書きますが、`Configuration#auth_settings` が
`Authorization` ヘッダに読むのは `api_key['BearerToken']`。キーがずれているため
**そのままでは Authorization ヘッダが空 → 401** になります。kuberails は
`Client.build` 時に `authorization` を `BearerToken` に複製する「K1 橋渡し」を
自動で行います（`BearerToken` が既に設定されていれば上書きしません）。
kruby 本体の挙動（gem の外側）に依存するクラスタ接続で 401 が出たら、まず
このトークンキーの問題を確認してください。

## License

MIT（[LICENSE](LICENSE)）
