# k8s-rails 設計書

- 文書番号: KBR-DESIGN-001
- 版: 0.1.12（案）
- 日付: 2026-09-15
- 対象リポジトリ: k8s-rails（本設計の実装先）
- ライセンス: MIT（LICENSE は main に既存）

---

## 1. 目的

Rails アプリが Kubernetes API を扱う際の**接続・CRD アクセス・障害処理の規約層**を
gem（`k8s-rails`）として提供する。

起点となった実際の Rails アプリ実装には、公式 `kruby` クライアントを
Rails アプリで実運用する過程で得られた知見が実装として固定されている:

| # | 知見（実運用で確認済み） |
|---|---|
| K1 | in-cluster（ServiceAccount）と KUBECONFIG の接続自動切替は `Kubernetes::Configuration.default_config` が担うが、**kruby 1.36 では in-cluster 時の `api_key['authorization']`（Bearer トークン）が `auth_settings` が読む `api_key['BearerToken']` に書かれず、Authorization ヘッダが欠落して 401 になる**。この橋渡しを忘れると本番（in-cluster）で必ず失敗する |
| K2 | kruby はシンボルキーの Hash を返す。Rails 側（JSON/ビュー）では文字列キーで扱うため、文字列キーへの統一変換が必須（gem 内部で処理: ActiveSupport 存在時は `deep_stringify_keys`、無ければ純 Ruby の再帰変換。Rails 無し環境でも成立、§5.2） |
| K3 | クラスタが到達不能な場合、呼び出し側（ビュー等）が生の `kruby` 例外を扱うと 500 になる。接続不能 / リソース不在 / API エラーを**gem 側の例外体系**で格納し、Rails 側はそれを素通し表示できる規約が必要 |
| K4 | read-only（get/list）と操作（create/patch/update）は障害時の影響度が異なるため、**フェーズごとに API を分離**する運用（read-only のみ → 操作追加）が事実上のベストプラクティス |
| K5 | CRD へのアクセスは group/version/plural をハードコードしがち。宣言でメソッドを生成すると typo による 404 を減らせる |

本 gem はこれらを**規約として標準化**し、(a) 新規 Rails アプリが 5 行程度の設定で
K8s CRD を扱えるようにし、(b) 実際の consumer アプリをこの gem に移行して両方向で検証する。

## 2. スコープ

### 2.1 本設計で扱うもの

- gem `k8s-rails` のアーキテクチャ・公開 API の設計
- 依存ポリシー（kruby pin、ActiveSupport の扱い）
- 例外体系・障害時の挙動定義
- テスト戦略（スタブによるユニットテスト、クラスタ不要）
- v0.1 / v0.2 のリリース境界
- consumer アプリへの移行手順（v0.1 検証の受け皿）

### 2.2 非スコープ（本設計の外）

- core v1 リソース（Pod / Deployment / Service 等）のフルサポート — CRD 中心の gem。core v1 は built-in リソースであり CustomObjects API では扱えない（`group=""`/`version="v1"` の宣言は**無効**）ため、別途 core API 経路が必要。v0.1 では対象外（将来候補、§11）
- **watch（ストリーム）** — v0.1 では非対応。kruby の watch は get/list より成熟度が低く、初版の API 保証範囲から外す（§11 で v0.2 候補）
- アプリの**デプロイ**（helm / kustomize 生成等） — `kuby-core` の領域
- RBAC 権限の付与・管理 — 呼び出しアプリ側の ClusterRole/Role の責務
- 複数クラスタ同時接続 — v0.1 は単一クラスタ前提（§11 展望）

### 2.3 前提

| # | 前提 |
|---|------|
| P1 | 実行環境は Kubernetes 1.27 以降を想定。API は 1.27〜1.31 系で動作確認 |
| P2 | クライアントは `kruby`（公式 OpenAPI クライアント系）。consumer アプリと同一の `~> 1.36.0` を基本 pin |
| P3 | 認証は (a) in-cluster ServiceAccount、(b) KUBECONFIG の 2 パターンのみを扱う。exec plugin / 他方式は v0.1 で保証しない |
| P4 | consumer アプリの K8s 利用（Argo Workflows / CronWorkflow 等の CRD）が、本 gem の移行検証の**最初かつ最低限のユースケース**である |

## 3. 全体構成

```
┌────────────────────────────────────────────────────┐
│ Rails アプリ（呼び出し側）                            │
│  K8sRails.configure { |c| c.namespace = "app" }   │
│  K8sRails.crd(group:, version:, plural:, kind:)   │
│                                                     │
│  MyApp::Workflow.list / .find / .create / .patch    │
└──────────────────────────┬─────────────────────────┘
                           │ 例外: K8sRails::Unavailable / ::NotFound / ::ApiError
┌──────────────────────────┴─────────────────────────┐
│ k8s-rails（本 gem）                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────┐ │
│  │ Config        │  │ Client       │  │ CRD       │ │
│  │ (initializer) │→ │ (接続解決+橋 │→ │ Resource  │ │
│  │               │  │ 渡し+計測)   │  │ (メソッド生成)│
│  └──────────────┘  └──────┬───────┘  └─────┬─────┘ │
│                           │                │        │
│  例外体系: Unavailable / NotFound / ApiError│        │
│  計測: ActiveSupport::Notifications (任意)    │        │
└──────────────────────────┴────────────────┼────────┘
                           │                │
┌──────────────────────────┴────────────────┴────────┐
│ kruby (~> 1.36.0) → Kubernetes API Server           │
│  (KUBECONFIG | ~/.kube/config | in-cluster SA token) │
│  ※kruby 1.36.x の探索順序は左→右（in-cluster は最後）  │
└────────────────────────────────────────────────────┘
```

データフローの原則:

- 呼び出しアプリは kruby に**直接触れない**（例外はテスト用注入のみ）。
  `K8sRails::Client` を挟むことで、kruby の API 変化・キー種別問題は gem 内部に封じ込める。
- クラスタ未接続でも gem のロード・設定は**副作用なし**で完了する（lazy connect）。
  接続は最初の API 呼び出し時（§5.2）。

## 4. ディレクトリ構成（gem 本体）

```
k8s-rails/
├── k8s-rails.gemspec
├── Gemfile                  # gemspec 参照 + 開発依存 (rspec, rubocop)
├── Rakefile
├── README.md
├── LICENSE                  # 既にある MIT（Dorian - Takahiro Ishida）
├── docs/
│   └── design.md            # 本設計書
├── lib/
│   ├── k8s-rails.rb         # エントリ。require 集 + モジュール定義
│   └── k8s_rails/
│       ├── version.rb       # VERSION = "0.2.0"
│       ├── configuration.rb # Config: namespace, connection, 計測 ON/OFF
│       ├── client.rb        # 接続解決・BearerToken 橋渡し・計測ラップ
│       ├── crd.rb           # K8sRails.crd 宣言 → Resource 生成
│       ├── resource.rb      # list/find/create/patch（生成先の基底クラス）
│       └── errors.rb        # Unavailable / NotFound / ApiError
├── spec/
│   ├── spec_helper.rb
│   ├── k8s_rails_spec.rb    # 設定 / lazy connect
│   ├── client_spec.rb       # 橋渡し・計測・例外変換
│   ├── crd_spec.rb          # 宣言 → メソッド生成
│   └── resource_spec.rb     # list/find/create/patch の整形
└── examples/
    └── rails-app/           # 最小 Rails 7.1 例（consumer 移行の雛形兼用）
```

## 5. 公開 API 設計

### 5.1 設定

```ruby
# config/initializers/k8s-rails.rb
K8sRails.configure do |config|
  config.namespace = ENV.fetch("K8S_NAMESPACE", "default")
  # 任意上書き（省略時は default_config の自動検出。kruby 1.36.x の探索順序は
  # KUBECONFIG → ~/.kube/config → in-cluster で、in-cluster が最後）
  # config.connection = Kubernetes::Configuration.default_config
  # config.instrumentation = true   # 既定 true（ActiveSupport 存在時のみ有効）
end
```

設定項目:

| キー | 既定 | 説明 |
|---|---|---|
| `namespace` | `"default"` | CRD 宣言が namespace 未指定時のデフォルト |
| `connection` | `nil`（自動検出） | `Kubernetes::Configuration` インスタンス。認証を上書きする場合に指定。省略時の探索順序（kruby 1.36.x の loader 実装順）: **KUBECONFIG → `~/.kube/config` → in-cluster**（in-cluster はファイル系が両方無効な場合の**最後**。kruby 上げ替え時に loader を再確認すること — §7） |
| `api_client` | `nil` | **テスト専用**: kruby の `CustomObjectsApi` と同型のメソッド（namespaced 4 メソッド `get_namespaced_custom_object` / `list_namespaced_custom_object` / `create_namespaced_custom_object` / `patch_namespaced_custom_object` ＋ cluster 4 メソッド `get_cluster_custom_object` / `list_cluster_custom_object` / `create_cluster_custom_object` / `patch_cluster_custom_object`）を実装する素のオブジェクト（namespaced 宣言のみを使う場合は namespaced 4 メソッドで足りる）。指定時は `Client.build` が接続解決をスキープして `StringKeyedAdapter` で包んで使う（§5.2・§9） |
| `instrumentation` | `true` | `ActiveSupport::Notifications` で計測する（§8） |

- 設定は `K8sRails.configure` で**一度だけ**。再実行は警告（`Warning`）+ 無視。
  **「一度だけ」はブロックが正常終了した場合に限る**: ブロックが異常終了した
  （任意の例外送出 — `LoadError` / `ScriptError` を含む — / `throw` /
  non-local return 等）場合は設定済みフラグがリセットされ、後続の `configure`
  は通常どおり実行される。ただし異常終了前に書き込まれた属性は共有 Configuration
  に**残存する**（部分的な設定状態になり得るため、再実行ブロックは依存する属性を
  全て設定する責務を負う。アトミックなロールバックは行わない — Configuration
  は純データで 4 属性のみのため、複写＋スワップの複雑さに見合わない）。
- `K8sRails.reset!`（テスト用）で接続キャッシュ・宣言済 CRD を破棄できる。

### 5.2 接続

```ruby
K8sRails::Client.build   # → Kubernetes::CustomObjectsApi（lazy。初回呼び出し時に接続）
K8sRails.connected?      # → 成功時は true。失敗は K8sRails::Unavailable / ApiError を raise
                          #   （false を返す経路なし）。/version 相当の軽量確認
                          #   （kruby 1.36.x の VersionApi#get_code（GET /version/）1 回）
                          #   `config.api_client` 注入時は I/O なしで true（§5.1 の
                          #   注入が接続面そのものだから。Resource 操作と整合させる）
```

`Client.build` が内部で行うこと（consumer アプリの K8s サービスの custom objects 生成部を移設）:

0. `config.api_client` があれば（テスト注入、§5.1）それを直接返し、以降の接続解決をスキップ
1. `config.connection` があればそれ、なければ `Kubernetes::Configuration.default_config`
2. **K1 橋渡し**: `api_key['authorization']` が `api_key['BearerToken']` に書かれていなければ複製
3. `Kubernetes::ApiClient` → `Kubernetes::CustomObjectsApi` を生成し、**文字列キー化**（K2）を API レスポンス後に行う。ActiveSupport 非依存の gem 内部の純 Ruby 再帰変換（`K8sRails::Normalizer`）を使う（v0.1.1 以降: 常に Normalizer。`deep_stringify_keys` 経路は廃止）
4. **接続レベルの失敗**（DNS 失敗 / タイムアウト / 接続拒否等）は `K8sRails::Unavailable` に変換して `raise`（リトライはしない）。**kruby 1.36.x ではこれらの転送失敗は HTTP ステータスが無いため `Kubernetes::ApiError`（`code == 0`）として surfacing する**（§5.4 の変換表参照）。認可失敗（401/403）は §5.4 により `K8sRails::ApiError`

`connected?` の解決順序:

0. `config.api_client` があれば（テスト注入、§5.1）**I/O なしで `true` を返す**。注入されたトランスポートが接続面そのもののため、実エンドポイントへのプローブは同一注入下の Resource 操作と矛盾する（#18 対応）。クラスタ到達性の真の確認が必要な場合は注入を解除した環境で行う
1. 以下 `Client.build` と同一（`config.connection` → `default_config` → K1 橋渡し → VersionApi プローブ）

### 5.3 CRD 宣言

```ruby
# config/initializers/k8s-rails_crd.rb（またはアプリケーションクラス内）
Workflow = K8sRails.crd(
  group:  "argoproj.io",
  version: "v1alpha1",
  plural: "workflows",
  kind:   "Workflow",
  namespace: K8sRails.config.namespace,   # 省略可
  readonly: false,                          # 既定 true。false で create/patch 有効化（K4）
)

# cluster-scoped CRD（ClusterIssuer / ClusterWorkflowTemplate 等）は
# scope: :cluster を付け、namespace: は省略する（併用は ArgumentError）
ClusterIssuer = K8sRails.crd(
  group:  "cert-manager.io",
  version: "v1",
  plural: "clusterissuers",
  kind:   "ClusterIssuer",
  scope: :cluster,
)
```

宣言で生成されるメソッド（全て class メソッド。namespaced 系は任意の `namespace:` 引数を受け取り、宣言時のデフォルト namespace を上書き可能）:

| メソッド | 引数 | 戻り値 | readonly 制限 |
|---|---|---|---|
| `list` | `{}` | `[{"name" => "...", "labels" => {}, "spec" => {}, "status" => {}}, ...]`（**文字列キー**） | 常に有効 |
| `find(name)` | 必須 | 同型 or `K8sRails::NotFound`（raise） | 常に有効 |
| `create(attributes)` | CRD body hash | 作成済みオブジェクト（文字列キー） | `readonly: false` のみ |
| `patch(name, operations)` | JSON Patch 操作配列 | 更新済みオブジェクト | `readonly: false` のみ |
| `list_cluster` | `{}` | 同上（クラスタ横断。`namespace:` なし） | 常に有効 |
| `find_cluster(name)` | 必須 | 同上 or `K8sRails::NotFound` | 常に有効 |
| `create_cluster(attributes)` | CRD body hash | 作成済みオブジェクト | `readonly: false` のみ |
| `patch_cluster(name, operations)` | JSON Patch 操作配列 | 更新済みオブジェクト | `readonly: false` のみ |

スコープの契約（#17 対応）:

- `scope: :namespaced`（既定）の宣言では `*_cluster` メソッドは `ArgumentError`（CRD が namespaced のためクラスタ endpoint を呼んでも 404 になるだけ）。
- `scope: :cluster` の宣言では素の `list` / `find` / `create` / `patch` は `ArgumentError`（namespaced endpoint を呼ぶと 404 になるだけ。`namespace:` 引数は意味を持たない）。
- 宣言時に `scope: :cluster` と `namespace:` を併用した場合は `ArgumentError`（設定ミスの fail fast）。
- transport は kruby の `*_cluster_custom_object` 4 メソッド（`namespace` 非持参の endpoint）を使う。テスト注入スタブは 2 セット 8 メソッドを実装する（§9）。

- **戻り値は常に文字列キーの Hash**（K2 の規約を API 契約として固定）。
  `find` は存在しない場合 `K8sRails::NotFound` を raise（consumer アプリ側が `return nil` にしていたのは
  呼び出し側の都合。gem としては例外が明示的）。「存在しない場合は nil」が欲しい場合は
  `find_or_nil(name)` を併設する。
- `plural` / `kind` は自動推測しない（`workflows` / `Workflow` 等、推測が外れる CRD が多い）。
  宣言で必ず指定する（K5）。
- 同名 CRD の再宣言は `K8sRails::RedeclarationError`（設定ミス検出）。

### 5.4 例外体系（K3）

```ruby
K8sRails::Error < StandardError
├── K8sRails::Unavailable   # 接続不能・タイムアウト・DNS 失敗等（クラスタ起因）
├── K8sRails::NotFound      # リソース不在（HTTP 404）
├── K8sRails::ApiError      # その他の API エラー（401/403/409/422 等）。#code と #response を保持
├── K8sRails::ReadOnlyError      # readonly: true 宣言で create/patch が呼ばれた（設定ミス）
└── K8sRails::RedeclarationError # 同名 CRD の再宣言（設定ミス）
```

変換規則:

| kruby 側 | → gem 側 |
|---|---|
| kruby 転送層例外（DNS 失敗 / タイムアウト / 接続拒否等。kruby 1.36.x では **`ApiError`（`code == 0`）** として surfacing） | `Unavailable` |
| その他の `StandardError`（プログラミング/設定ミス、例: `NoMethodError`） | そのまま伝播（変換せず隠さない） |
| `Kubernetes::ApiError` code 404 | `NotFound` |
| `Kubernetes::ApiError` その他 | `ApiError`（code / response body を保持） |
| 宣言時に `readonly: true` で create/patch を呼ばれた | `K8sRails::ReadOnlyError`（**設定ミス**なので raise せずには済ませない） |

呼び出しアプリ（Rails）側の推奨パターン:

```ruby
begin
  workflows = Workflow.list
rescue K8sRails::Unavailable => e
  render "k8s_unavailable"        # consumer アプリの「K8s 未接続」バナー相当
rescue K8sRails::NotFound
  redirect_to root_path, alert: "Workflow が見つかりません"
end
```

## 6. 依存ポリシー

| 依存 | 制約 | 理由 |
|---|---|---|
| Ruby | `>= 3.3, < 4.0` | 下限: kruby 1.36.x が `required_ruby_version ">= 3.3"` を宣言（RubyGems API で実測 2026-09-21、1.36.0.1〜1.36.4.1 全バージョン）。上限: 「宣言した Ruby minor を必ず CI で検証する」方針（レビュー対応・2026-09-21）— 2026-09-21 時点で Ruby 4.0 は stable（v4.0.7）だが未検証、3.5 は preview（v3_5_0_preview1）のため、宣言範囲を 3.x に限定。4.0 / 3.5 対応は v0.2 以降で検証の上宣言に含める |
| `kruby` | `~> 1.36.0` | consumer アプリと同一 pin。`~> 1.36.0` は 1.36.x のみ許可（`~> 1.36` 形式は 1.37 以降も許容してしまうため使用しない）。新しめの kruby に対応する場合は §7 の確認事項（client.rb 8 メソッド（namespaced 4 + cluster 4）・K1 橋渡し・`default_config` 探索順序）を済ませてから明示的に上げ替える |
| `activesupport` | **任意**（`>= 7.0`） | `defined?(ActiveSupport::Notifications)` でガード（計測のみ、§8）。Rails 無し環境（Cron スクリプト等）でも動作する必要がある — レスポンスの文字列キー化（K2）はこれに依存せず、gem 内部の純 Ruby 変換で担う（§5.2） |
| `rspec` / `rubocop` | 開発依存 | spec / lint |

- kruby への依存は **`K8sRails::Client` に閉じ込める**（§7）。
  kruby 上げ替え時の修正箇所を 1 ファイルに限定し、CHANGELOG に「対応 kruby」を明記する。

## 7. 実装規約（kruby 変化への耐性）

- `lib/k8s_rails/client.rb` **のみ**が `require "kubernetes"` してよい。
  他のファイルは kruby 定数・クラスを参照しない。
- kruby の `CustomObjectsApi` メソッド呼び出しは `client.rb` 内の
  `*_namespaced_custom_object` の 4 メソッド（`get_namespaced_custom_object` 等）と
  `*_cluster_custom_object` の 4 メソッド（`get_cluster_custom_object` 等）に集約する。
  `resource.rb` は
  `K8sRails.client.get(group, version, ns, plural, name)` のような **gem 内部 API** だけを使う。
- kruby 上げ替え時の作業は (1) client.rb 8 メソッド（namespaced 4 + cluster 4）のシグネチャ確認、
  (2) K1 橋渡しの要否確認、(3) **`Kubernetes::Configuration.default_config` の探索順序確認**
  （kruby 1.36.x の loader 実装順は **KUBECONFIG → `~/.kube/config` → in-cluster** で in-cluster が
  最後。README / 設計書 / 設定コメントがこの順序を明記しているため、loader が変わった場合は
  全箇所を同期する — #19 対応）に収まることをテスト（§9）で担保する。

## 8. 計測（ActiveSupport 任意）

`instrumentation: true` かつ ActiveSupport 存在時、各 API 呼び出しを計測する:

```
k8s-rails.request  payload: { operation: :list, group:, version:, plural:, namespace:
                               # operation は symbol（:list / :find / :create / :patch）
                               duration_ms:  # float（ミリ秒・小数点 2 桁）
                               status: "ok" | "unavailable" | "api_error" }
```

- `status` は **文字列**（`"ok"` / `"unavailable"` / `"api_error"`）、
  `operation` は **symbol**。例外は notification を発した上で **そのまま raise**
  される（計測は swallow しない）。

- Rails アプリではこの notification を `ActiveSupport::Notifications` /
  `log_subscription` で拾える（ログ・ダッシュボード表示）。
- ActiveSupport 無い環境（または `instrumentation: false`）では no-op。
  この場合も **ブロックの戻り値はそのまま返る**（`nil` にはならない）。

## 9. テスト戦略（クラスタ不要）

| レイヤー | 手法 | 対象 |
|---|---|---|
| ユニット | `K8sRails.config.api_client` に**スタブ**（kruby `CustomObjectsApi` と同型のメソッド。namespaced 4 メソッド `get_namespaced_custom_object` / `list_namespaced_custom_object` / `create_namespaced_custom_object` / `patch_namespaced_custom_object` ＋ cluster 4 メソッド `get_cluster_custom_object` / `list_cluster_custom_object` / `create_cluster_custom_object` / `patch_cluster_custom_object` を実装する素のオブジェクト。`StringKeyedAdapter` がこの形式を呼ぶ）を注入 | client（橋渡し・例外変換）、resource（整形・readonly 制限・スコープ制限）、crd（メソッド生成・scope 検証） |
| 設定 | spec 間で `K8sRails.reset!` | 宣言の破棄・再接続 |
| 集積（任意） | GitHub Actions で **kind**（または既存 microk8s に接続するジョブ）で実クラスタ E2E | v0.1 の必須ではない。**推奨**: consumer アプリ移行時の検証を兼ねる |

- 本設計では CI は `rspec` + `rubocop` のみを必須とし、kind E2E は v0.2 以降で
  GitHub Actions の追加として扱う（実クラスタへの接続 CI はネットワーク依存のため採用しない）。

## 10. リリース計画

| バージョン | 内容 | 出口基準 |
|---|---|---|
| **v0.1** | §5 の公開 API（CRD 宣言 / list / find / create / patch / 例外 / 計測 / スタブテスト）+ README | rspec 全緑 + **consumer アプリの K8s サービスを `k8s-rails` に移行して動作確認**（§12） |
| **v0.2** | #16–#19 の公開 API 拡充・修正（cluster-scoped CRD `scope:` + `*_cluster` メソッド、`configure` のアトミック契約、`connected?` の注入契約、kruby loader 探索順序の修正）。設計書 v0.1.12（案） | rspec 全緑（クラスタ不要）+ 公開 gem push（v0.1.0 と同導線） |
| v0.3 | watch（`watch` メソッド、kruby の watch サポート上）、core v1 built-in リソース対応（CustomObjects API では不可なため別途 core API 経路、§2.2）、kind E2E の CI 化、Ruby 3.5 / 4.0 対応（検証の上宣言範囲・matrix を拡大） | v0.2 運用のフィードバック |
| v0.4 | （展望）複数クラスタ（ネームスペース化された client 集合）、リトライポリシー | — |

v0.1 の milestone 分割（開発セッション向けのタスク単位目安）:

1. M0 — gem 骨子: gemspec / Gemfile / Rakefile / version / require 構造（rspec が回せる状態）
2. M1 — Configuration + reset!（K1 橋渡しを含む Client 実装、例外変換）
3. M2 — CRD 宣言 DSL + Resource（list / find / find_or_nil / create / patch、readonly 制限）
4. M3 — 計測 + README + rubocop 設定
5. M4 — consumer アプリへの移行と検証（§12）

## 11. 展望・検討事項（v0.1 では確定しない）

- **watch**: kruby の watch はストリーム処理であり、Rails のリクエスト応答型には不向き。
  導入するなら「watch 開始 → メッセージをキュー / NotificationCenter 相当に流す」の
  形で、ポーリング置き換えのユースケース（consumer アプリの 30 秒ポーリング等）から設計する。
- **複数クラスタ**: `K8sRails.cluster("prod") { ... }` のような名前付き client 集合。
  現時点で需要がないため v0.1 では単一クラスタ。
- **retries / timeout**: kruby の `Kubernetes::Configuration` には接続タイムアウトが
  設定できる。v0.1 は既定値 + README 記載のみで、gem 独自のバックオフは持たない
  （Rails 側の middleware / sidekiq retry で吸収するのが慣習）。
- **OpenTelemetry**: `instrumentation` を notification 経由にしているため、
  OTel instrumentation を別途足せる状態に留める（v0.1 で実装しない）。

## 12. consumer アプリへの移行（v0.1 検証）

実際の consumer Rails アプリの K8s サービス（kruby 直接利用）を `k8s-rails` に置き換えて動作を確認する:

1. `Gemfile` に `gem "k8s-rails", path: "../k8s-rails"`（開発期間限定。公開後は registry 版）
2. initializer に CRD 宣言（Argo Workflows / CronWorkflow 等の該当 CRD、
   `readonly: false`（操作系があるため））
3. K8s サービス内の kruby 呼び出しを `K8sRails` 経由に置換。**整形メソッド
   （summary 系）は consumer アプリ側に残す**
   （アプリ固有の表示ロジックのため、gem には載せない）
4. 例外: consumer アプリの Unavailable 相当を `K8sRails::Unavailable` に alias/
   rescue 統一
5. 検証: consumer アプリのテスト + K8s 読取が KUBECONFIG 経由で
   従来通り表示されること（実クラスタへの手動確認）

移行後も K8s サービスを**整形ラッパーとして残す**（コントローラの呼び出し先を変えない、
PR の差分を最小化）。

## 13. 命名・公開

- **gem 名 / リポジトリ名: `k8s-rails`**（RubyGems で空きを確認済み 2026-09-21）。
  当初の名 `kuberails` は **push 時の類似名チェックで却下**された
  （RubyGems は名前のハイフンを無視して比較し、`kube-rails`（2015 年の旧 gem・
  取得済み）と正規化すると同一文字列になるため使用不可）。命名規則は
  **gem 名 = ハイフン**（`k8s-rails`）・**モジュール = CamelCase**（`K8sRails`）・
  **ファイル / ディレクトリ = snake_case**（`lib/k8s_rails/`。エントリのみ
  `lib/k8s-rails.rb` と require 名に合わせたハイフン）で統一する
- GitHub: `doridoridoriand/k8s-rails`（org `k8s-rails` は他者が使用済み。個人アカウント配下）
- 公開は v0.1 完成後、**ローカル PC から手動 `gem push`**（kruby と同様の運用方針・
  2026-09-21 確定）。CI による自動公開は行わない。
  - 手順（owner がローカル PC で実施）:
    1. `bundle exec rake`（spec + rubocop）が全緑であることを確認
    2. CHANGELOG.md の該当バージョン節を確定（「Unreleased」のまま公開しない）
    3. `gem signin`（RubyGems アカウント・未作成なら先に作成）
    4. `gem build k8s-rails.gemspec` → `gem push k8s-rails-<VERSION>.gem`
  - 未取得の gem は**初回 push が所有権の取得**（`gem owner` は `--add` による
    **追加** owner のみで、位置引数に user を取る構文は存在しない・
    gem 4.0.7 `gem owner --help` で実測 2026-09-21）
  - 公開直前に tag を切って **remote へ push** すると追溯性が高い
    （`git tag v<VERSION> && git push origin v<VERSION>`）。
    GitHub 上でリリースコミットと tag が対応付けられ、
    公開した gem のバージョンがどのコミットに基づくかを追跡できる。
    tag 名と gemspec の `VERSION` は一致させる
  - テスト CI（`.github/workflows/test.yml`）は push / PR 時に rspec + rubocop を実行。
    gemspec の宣言範囲（`>= 3.3, < 4.0`）を matrix で検証:
    3.3.0（下限・kruby 1.36.x の `>= 3.3`）・3.3.8（開発）・
    3.4.10（3.x 系の最新 stable・2026-09-21 時点。3.5 は preview、
    4.0 は宣言範囲外のため未検証・v0.2 以降で検討）。
    **宣言範囲を常に matrix がカバーする**こと（`< 4.0` 上限により、
    4.x のリリースは宣言範囲外。stable 化された新 3.x minor が出たら
    matrix への追加を忘れないこと）。
    テストはクラスタ不要（§9・スタブ注入）のため v0.1 は runner 上のユニットのみ。
    kind / 実クラスタ E2E の CI 化は v0.2 対象（§9・§10）
- `README` に「kruby pin」「対応 k8s バージョン（実測 v1.33.x で検証済み）」「K1 橋渡しの背景」
  を明記する（検索でヒットする重要な注意点のため）

## 14. 承認・変更履歴

| 版 | 日付 | 変更 | 承認 |
|---|---|---|---|
| 0.1 | 2026-09-15 | 初版（案）。実際の Rails アプリ実装の知見 K1–K5 を基に作成 | 未承認 |
| 0.1.1 | 2026-09-18 | PR #1 レビュー対応: 文字列キー化の純 Ruby 経路（ActiveSupport 非依存）、401/403→ApiError 統一、`throw`→`raise`、core v1 を built-in 扱いに修正、`~> 1.36.0` に統一、テスト注入の `api_client` 追加、例外ツリーに `ReadOnlyError`/`RedeclarationError` 追記、初期化子例を汎用化 | レビュー反映済み |
| 0.1.2 | 2026-09-18 | M1 実装にあたって kruby 1.36.2.1 を実機確認した差分を反映: `connected?` の endpoint を `VersionApi#get_code`（GET /version/）に修正、転送失敗（DNS/timeout/接続拒否）が `ApiError(code == 0)` として surfacing することを §5.2/§5.4 に明記、文字列キー化を常に `Normalizer`（`deep_stringify_keys` 経路廃止）に統一 | 実装反映済み |
| 0.1.3 | 2026-09-20 | M3 実装に伴う §8 の軽微明確化: notification の `operation` は symbol・`status` は文字列であること、例外は発火後そのまま raise（swallow しない）こと、no-op 時（AS 無 / instrumentation: false）もブロック値がそのまま返ること。加えて `connected?` の戻り値記述を実装に合わせ修正（false を返す経路なし・失敗は raise）、テストスタブのメソッド名を kruby `CustomObjectsApi` 形式（`*_namespaced_custom_object`）に修正 | 実装反映済み |
| 0.1.4 | 2026-09-21 | リリース準備（§13）: 公開導線を手動 `gem push` から**タグ基準の GitHub Actions**（`test.yml` / `publish.yml`）に更新、README に検証済み k8s サーババージョン（v1.33.x / microk8s v1.33.13）を追記、CHANGELOG.md を同梱、gemspec に `source_code_uri` / `changelog_uri` / `allowed_push_host` メタ情報を追加 | 実装反映済み |
| 0.1.5 | 2026-09-21 | PR #11 レビュー対応（Codex P2 + Copilot M/L 3 系統）: ①未取得 gem の owner 取得手順を「初回 push が所有権取得」に修正（`gem owner k8s-rails <user>` は無効構文・`gem owner --help` 実測、`--add` は追加のみ）・publish.yml / §13 ②テスト CI を Ruby 3.3.x matrix に（**`>= 3.2` は kruby 1.36.x の `>= 3.3` と非整合だったため、§6・gemspec・README の Ruby 下限を 3.3 に改訂**・RubyGems API で 1.36.x 全 7 バージョン実測）③tag 前の CHANGELOG 確定を手順化（publish workflow は CHANGELOG を書き換えないため） | 実装反映済み |
| 0.1.6 | 2026-09-21 | PR #11 レビュー第 2 波対応（Copilot ×2）: ①publish workflow に `verify` job（サポート Ruby 全バージョンの rake matrix）を追加し push job を `needs: verify` でゲート化（独立 Test workflow は tag 時に gem push をブロックできないため）・§13 ②テスト matrix の下限を 3.3.1 から **3.3.0** に（gemspec `>= 3.3` は 3.3.0 を含むため、宣言された最低バージョンを実際に検証） | 実装反映済み |
| 0.1.7 | 2026-09-21 | PR #11 レビュー第 3 波対応（Copilot ×1）: `>= 3.3` が Ruby 3.4+ も含むため、テスト / verify matrix に **3.4.10（最新 stable・ruby-lang.org 実測）** を追加（3.3.0 / 3.3.8 / 3.4.10 の 3 系統）。新しい stable minor が出た際の matrix 追加を §13 に手順として明記 | 実装反映済み |
| 0.1.8 | 2026-09-21 | PR #11 レビュー第 4 波対応（Copilot ×3）: 指摘（「Ruby 3.5 が stable 化したため matrix に追加せよ」）を検証した結果 **3.5 は preview であり claim は誤り**（ruby/ruby タグ `v3_5_0_preview1`・2026-09-21 実測）と判明。ただし指摘の根本（宣言と検証範囲のズレ）は**Ruby 4.0 が stable（v4.0.7）だったため**実際に存在した。対策として宣言範囲を **`>= 3.3, < 4.0` に改訂**（gemspec / §6 / README / CHANGELOG）し、宣言範囲 = matrix 検証範囲（3.3.0 / 3.3.8 / 3.4.10）を一致。4.0 / 3.5 対応は v0.2 以降で検証の上宣言に含める方針 | 実装反映済み |
| 0.1.9 | 2026-09-21 | public リポジトリ化の準備: ①公開導線を**ローカル PC から手動 `gem push`** に変更（kruby と同様の運用方針・CI 自動公開は廃止、publish workflow を削除、test workflow の push/PR テストのみ残す）②§13 公開手順の手動化（tag は追溯性のため推奨）③内部 consumer アプリの名称・構造への言及を §1〜§14 全箇所から除去し「consumer アプリ」に一般化 | 実装反映済み |
| 0.1.10 | 2026-09-21 | PR #12 レビュー対応（Copilot）: §13 の公開手順で tag の **remote への push**（`git push origin v<VERSION>`）が欠落しており、GitHub 上のリリースコミットとの対応付け（追溯性）が確保できないとの指摘を反映 | 実装反映済み |
| 0.1.11 | 2026-09-22 | Issue #16–#19 対応: ①#16 `configure` の例外送出時は設定済みフラグをリセット（「一度だけ」はブロック正常終了時にのみ成立）。例外前に書かれた属性は残存することを契約として明文化（§5.1）②#17 `scope: :namespaced`（既定）/ `:cluster` を宣言 API に追加。cluster 系 4 メソッド（`list_cluster` / `find_cluster` / `find_or_nil_cluster` / `create_cluster` / `patch_cluster`）と双方向の ArgumentError 契約（§5.3）。transport は kruby の `*_cluster_custom_object` 4 メソッドを新たに使用③#18 `connected?` は `config.api_client` 注入時に I/O なしで `true`（§5.2）。注入下で Resource 操作と接続確認の挙動を一致させる④#19 kruby 1.36.x の loader 実装順（**KUBECONFIG → `~/.kube/config` → in-cluster**）を README / 設計書 / 設定コメントに明記し、§7 の上げ替え確認事項に探索順序の再確認を追加（in-cluster は最後。従来の「in-cluster → KUBECONFIG」記述は誤り） | 実装反映済み |
| 0.1.12 | 2026-09-22 | PR #20 レビュー対応（Codex P2 + Copilot M/L 4 系統）: ①#16 のリセット範囲を `rescue StandardError` から**任意の異常終了**（`LoadError` / `ScriptError` / `throw` / non-local return 等）に拡大（成功マーカー + `ensure` で実装、spec 2 件追加）。§5.1 / README の契約文言も「任意の異常終了」に修正②README の「`namespace:` 引数を受け取る」記述を namespaced メソッドに限定（`*_cluster` は受け付けない）③§6 の kruby 上げ替え確認事項を 8 メソッド + 探索順序に同期④`api_client` 注入スタブの契約を namespaced 4 + cluster 4 の 8 メソッドに統一（§5.1 表 / configuration.rb コメント / §9） | 実装反映済み |
