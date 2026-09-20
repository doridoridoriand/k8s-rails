# kuberails 設計書

- 文書番号: KBR-DESIGN-001
- 版: 0.1.4（案）
- 日付: 2026-09-15
- 対象リポジトリ: kuberails（本設計の実装先）
- 参照元: consumer app `app/services/k8s_service.rb`（経験の元になった実装）
- ライセンス: MIT（LICENSE は main に既存）

---

## 1. 目的

Rails アプリが Kubernetes API を扱う際の**接続・CRD アクセス・障害処理の規約層**を
gem（`kuberails`）として提供する。

起点となった consumer app の `consumer app 側の K8s service` には、公式 `kruby` クライアントを
Rails アプリで実運用する過程で得られた知見が実装として固定されている:

| # | 知見（consumer app 実装で確認済み） |
|---|---|
| K1 | in-cluster（ServiceAccount）と KUBECONFIG の接続自動切替は `Kubernetes::Configuration.default_config` が担うが、**kruby 1.36 では in-cluster 時の `api_key['authorization']`（Bearer トークン）が `auth_settings` が読む `api_key['BearerToken']` に書かれず、Authorization ヘッダが欠落して 401 になる**。この橋渡しを忘れると本番（in-cluster）で必ず失敗する |
| K2 | kruby はシンボルキーの Hash を返す。Rails 側（JSON/ビュー）では文字列キーで扱うため、文字列キーへの統一変換が必須（gem 内部で処理: ActiveSupport 存在時は `deep_stringify_keys`、無ければ純 Ruby の再帰変換。Rails 無し環境でも成立、§5.2） |
| K3 | クラスタが到達不能な場合、呼び出し側（ビュー等）が生の `kruby` 例外を扱うと 500 になる。接続不能 / リソース不在 / API エラーを**gem 側の例外体系**で格納し、Rails 側はそれを素通し表示できる規約が必要 |
| K4 | read-only（get/list）と操作（create/patch/update）は障害時の影響度が異なるため、**フェーズごとに API を分離**する運用（consumer app の M2 read-only → M3 操作）が事実上のベストプラクティス |
| K5 | CRD へのアクセスは group/version/plural をハードコードしがち。宣言でメソッドを生成すると typo による 404 を減らせる |

本 gem はこれらを**規約として標準化**し、(a) 新規 Rails アプリが 5 行程度の設定で
K8s CRD を扱えるようにし、(b) consumer app 自体をこの gem に移行して両方向で検証する。

## 2. スコープ

### 2.1 本設計で扱うもの

- gem `kuberails` のアーキテクチャ・公開 API の設計
- 依存ポリシー（kruby pin、ActiveSupport の扱い）
- 例外体系・障害時の挙動定義
- テスト戦略（スタブによるユニットテスト、クラスタ不要）
- v0.1 / v0.2 のリリース境界
- consumer app への移行手順（v0.1 検証の受け皿）

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
| P2 | クライアントは `kruby`（公式 OpenAPI クライアント系）。consumer app と同様に `~> 1.36.0` を基本 pin |
| P3 | 認証は (a) in-cluster ServiceAccount、(b) KUBECONFIG の 2 パターンのみを扱う。exec plugin / 他方式は v0.1 で保証しない |
| P4 | consumer app の K8s 利用（Argo Workflows / CronWorkflow / crawl-progress CR）が、本 gem の移行検証の**最初かつ最低限のユースケース**である |

## 3. 全体構成

```
┌────────────────────────────────────────────────────┐
│ Rails アプリ（呼び出し側）                            │
│  KubeRails.configure { |c| c.namespace = "app" }   │
│  KubeRails.crd(group:, version:, plural:, kind:)   │
│                                                     │
│  MyApp::Workflow.list / .find / .create / .patch    │
└──────────────────────────┬─────────────────────────┘
                           │ 例外: KubeRails::Unavailable / ::NotFound / ::ApiError
┌──────────────────────────┴─────────────────────────┐
│ kuberails（本 gem）                                  │
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
│  (in-cluster SA token | KUBECONFIG)                 │
└────────────────────────────────────────────────────┘
```

データフローの原則:

- 呼び出しアプリは kruby に**直接触れない**（例外はテスト用注入のみ）。
  `KubeRails::Client` を挟むことで、kruby の API 変化・キー種別問題は gem 内部に封じ込める。
- クラスタ未接続でも gem のロード・設定は**副作用なし**で完了する（lazy connect）。
  接続は最初の API 呼び出し時（§5.2）。

## 4. ディレクトリ構成（gem 本体）

```
kuberails/
├── kuberails.gemspec
├── Gemfile                  # gemspec 参照 + 開発依存 (rspec, rubocop)
├── Rakefile
├── README.md
├── LICENSE                  # 既にある MIT（Dorian - Takahiro Ishida）
├── docs/
│   └── design.md            # 本設計書
├── lib/
│   ├── kuberails.rb         # エントリ。require 集 + モジュール定義
│   └── kuberails/
│       ├── version.rb       # VERSION = "0.1.0"
│       ├── configuration.rb # Config: namespace, connection, 計測 ON/OFF
│       ├── client.rb        # 接続解決・BearerToken 橋渡し・計測ラップ
│       ├── crd.rb           # KubeRails.crd 宣言 → Resource 生成
│       ├── resource.rb      # list/find/create/patch（生成先の基底クラス）
│       └── errors.rb        # Unavailable / NotFound / ApiError
├── spec/
│   ├── spec_helper.rb
│   ├── kuberails_spec.rb    # 設定 / lazy connect
│   ├── client_spec.rb       # 橋渡し・計測・例外変換
│   ├── crd_spec.rb          # 宣言 → メソッド生成
│   └── resource_spec.rb     # list/find/create/patch の整形
└── examples/
    └── rails-app/           # 最小 Rails 7.1 例（consumer app 移行の雛形兼用）
```

## 5. 公開 API 設計

### 5.1 設定

```ruby
# config/initializers/kuberails.rb
KubeRails.configure do |config|
  config.namespace = ENV.fetch("K8S_NAMESPACE", "default")
  # 任意上書き（省略時は default_config の自動検出: in-cluster → KUBECONFIG）
  # config.connection = Kubernetes::Configuration.default_config
  # config.instrumentation = true   # 既定 true（ActiveSupport 存在時のみ有効）
end
```

設定項目:

| キー | 既定 | 説明 |
|---|---|---|
| `namespace` | `"default"` | CRD 宣言が namespace 未指定時のデフォルト |
| `connection` | `nil`（自動検出） | `Kubernetes::Configuration` インスタンス。認証を上書きする場合に指定 |
| `api_client` | `nil` | **テスト専用**: kruby の `CustomObjectsApi` と同型の 4 メソッド（`get_namespaced_custom_object` / `list_namespaced_custom_object` / `create_namespaced_custom_object` / `patch_namespaced_custom_object`）を実装する素のオブジェクト。指定時は `Client.build` が接続解決をスキープして `StringKeyedAdapter` で包んで使う（§5.2・§9） |
| `instrumentation` | `true` | `ActiveSupport::Notifications` で計測する（§8） |

- 設定は `KubeRails.configure` で**一度だけ**。再実行は警告（`Warning`）+ 無視。
- `KubeRails.reset!`（テスト用）で接続キャッシュ・宣言済 CRD を破棄できる。

### 5.2 接続

```ruby
KubeRails::Client.build   # → Kubernetes::CustomObjectsApi（lazy。初回呼び出し時に接続）
KubeRails.connected?      # → 成功時は true。失敗は KubeRails::Unavailable / ApiError を raise
                          #   （false を返す経路なし）。/version 相当の軽量確認
                          #   （kruby 1.36.x の VersionApi#get_code（GET /version/）1 回）
```

`Client.build` が内部で行うこと（consumer app `consumer app 側の custom_objects_api` の中身を移設）:

0. `config.api_client` があれば（テスト注入、§5.1）それを直接返し、以降の接続解決をスキップ
1. `config.connection` があればそれ、なければ `Kubernetes::Configuration.default_config`
2. **K1 橋渡し**: `api_key['authorization']` が `api_key['BearerToken']` に書かれていなければ複製
3. `Kubernetes::ApiClient` → `Kubernetes::CustomObjectsApi` を生成し、**文字列キー化**（K2）を API レスポンス後に行う。ActiveSupport 非依存の gem 内部の純 Ruby 再帰変換（`KubeRails::Normalizer`）を使う（v0.1.1 以降: 常に Normalizer。`deep_stringify_keys` 経路は廃止）
4. **接続レベルの失敗**（DNS 失敗 / タイムアウト / 接続拒否等）は `KubeRails::Unavailable` に変換して `raise`（リトライはしない）。**kruby 1.36.x ではこれらの転送失敗は HTTP ステータスが無いため `Kubernetes::ApiError`（`code == 0`）として surfacing する**（§5.4 の変換表参照）。認可失敗（401/403）は §5.4 により `KubeRails::ApiError`

### 5.3 CRD 宣言

```ruby
# config/initializers/kuberails_crd.rb（またはアプリケーションクラス内）
Workflow = KubeRails.crd(
  group:  "argoproj.io",
  version: "v1alpha1",
  plural: "workflows",
  kind:   "Workflow",
  namespace: KubeRails.config.namespace,   # 省略可
  readonly: false,                          # 既定 true。false で create/patch 有効化（K4）
)
```

宣言で生成されるメソッド（全て class メソッド。各メソッドは任意の `namespace:` 引数を受け取り、宣言時のデフォルト namespace を上書き可能）:

| メソッド | 引数 | 戻り値 | readonly 制限 |
|---|---|---|---|
| `list` | `{}` | `[{"name" => "...", "labels" => {}, "spec" => {}, "status" => {}}, ...]`（**文字列キー**） | 常に有効 |
| `find(name)` | 必須 | 同型 or `KubeRails::NotFound`（raise） | 常に有効 |
| `create(attributes)` | CRD body hash | 作成済みオブジェクト（文字列キー） | `readonly: false` のみ |
| `patch(name, operations)` | JSON Patch 操作配列 | 更新済みオブジェクト | `readonly: false` のみ |

- **戻り値は常に文字列キーの Hash**（K2 の規約を API 契約として固定）。
  `find` は存在しない場合 `KubeRails::NotFound` を raise（consumer app が `return nil` にしていたのは
  呼び出し側の都合。gem としては例外が明示的）。「存在しない場合は nil」が欲しい場合は
  `find_or_nil(name)` を併設する。
- `plural` / `kind` は自動推測しない（`workflows` / `Workflow` 等、推測が外れる CRD が多い）。
  宣言で必ず指定する（K5）。
- 同名 CRD の再宣言は `KubeRails::RedeclarationError`（設定ミス検出）。

### 5.4 例外体系（K3）

```ruby
KubeRails::Error < StandardError
├── KubeRails::Unavailable   # 接続不能・タイムアウト・DNS 失敗等（クラスタ起因）
├── KubeRails::NotFound      # リソース不在（HTTP 404）
├── KubeRails::ApiError      # その他の API エラー（401/403/409/422 等）。#code と #response を保持
├── KubeRails::ReadOnlyError      # readonly: true 宣言で create/patch が呼ばれた（設定ミス）
└── KubeRails::RedeclarationError # 同名 CRD の再宣言（設定ミス）
```

変換規則:

| kruby 側 | → gem 側 |
|---|---|
| kruby 転送層例外（DNS 失敗 / タイムアウト / 接続拒否等。kruby 1.36.x では **`ApiError`（`code == 0`）** として surfacing） | `Unavailable` |
| その他の `StandardError`（プログラミング/設定ミス、例: `NoMethodError`） | そのまま伝播（変換せず隠さない） |
| `Kubernetes::ApiError` code 404 | `NotFound` |
| `Kubernetes::ApiError` その他 | `ApiError`（code / response body を保持） |
| 宣言時に `readonly: true` で create/patch を呼ばれた | `KubeRails::ReadOnlyError`（**設定ミス**なので raise せずには済ませない） |

呼び出しアプリ（Rails）側の推奨パターン:

```ruby
begin
  workflows = Workflow.list
rescue KubeRails::Unavailable => e
  render "k8s_unavailable"        # consumer app の「K8s 未接続」バナー相当
rescue KubeRails::NotFound
  redirect_to root_path, alert: "Workflow が見つかりません"
end
```

## 6. 依存ポリシー

| 依存 | 制約 | 理由 |
|---|---|---|
| Ruby | `>= 3.2` | consumer app が 3.3.8 実行。gem として広く使う 3.2 を下限に |
| `kruby` | `~> 1.36.0` | consumer app と同一 pin。`~> 1.36.0` は 1.36.x のみ許可（`~> 1.36` 形式は 1.37 以降も許容してしまうため使用しない）。新しめの kruby に対応する場合は §7 の確認事項（client.rb 4 メソッド・K1 橋渡し）を済ませてから明示的に上げ替える |
| `activesupport` | **任意**（`>= 7.0`） | `defined?(ActiveSupport::Notifications)` でガード（計測のみ、§8）。Rails 無し環境（Cron スクリプト等）でも動作する必要がある — レスポンスの文字列キー化（K2）はこれに依存せず、gem 内部の純 Ruby 変換で担う（§5.2） |
| `rspec` / `rubocop` | 開発依存 | spec / lint |

- kruby への依存は **`KubeRails::Client` に閉じ込める**（§7）。
  kruby 上げ替え時の修正箇所を 1 ファイルに限定し、CHANGELOG に「対応 kruby」を明記する。

## 7. 実装規約（kruby 変化への耐性）

- `lib/kuberails/client.rb` **のみ**が `require "kubernetes"` してよい。
  他のファイルは kruby 定数・クラスを参照しない。
- kruby の `CustomObjectsApi` メソッド呼び出しは `client.rb` 内の
  `*_namespaced_custom_object` の 4 メソッド（`get_namespaced_custom_object` 等）に集約する。`resource.rb` は
  `KubeRails.client.get(group, version, ns, plural, name)` のような **gem 内部 API** だけを使う。
- kruby 上げ替え時の作業は (1) client.rb 4 メソッドのシグネチャ確認、
  (2) K1 橋渡しの要否確認、に収まることをテスト（§9）で担保する。

## 8. 計測（ActiveSupport 任意）

`instrumentation: true` かつ ActiveSupport 存在時、各 API 呼び出しを計測する:

```
kuberails.request  payload: { operation: :list, group:, version:, plural:, namespace:
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
| ユニット | `KubeRails.config.api_client` に**スタブ**（kruby `CustomObjectsApi` と同型の 4 メソッド `get_namespaced_custom_object` / `list_namespaced_custom_object` / `create_namespaced_custom_object` / `patch_namespaced_custom_object` を実装する素のオブジェクト。`StringKeyedAdapter` がこの形式を呼ぶ）を注入 | client（橋渡し・例外変換）、resource（整形・readonly 制限）、crd（メソッド生成） |
| 設定 | spec 間で `KubeRails.reset!` | 宣言の破棄・再接続 |
| 集積（任意） | GitHub Actions で **kind**（または既存 microk8s に接続するジョブ）で実クラスタ E2E | v0.1 の必須ではない。**推奨**: consumer app 移行時の検証を兼ねる |

- 本設計では CI は `rspec` + `rubocop` のみを必須とし、kind E2E は v0.2 以降で
  GitHub Actions の追加として扱う（実クラスタ への接続 CI はネットワーク依存のため採用しない）。

## 10. リリース計画

| バージョン | 内容 | 出口基準 |
|---|---|---|
| **v0.1** | §5 の公開 API（CRD 宣言 / list / find / create / patch / 例外 / 計測 / スタブテスト）+ README | rspec 全緑 + **consumer app の `consumer app 側の K8s service` を `kuberails` に移行して動作確認**（§12） |
| v0.2 | watch（`watch` メソッド、kruby の watch サポート上）、core v1 built-in リソース対応（CustomObjects API では不可なため別途 core API 経路、§2.2）、kind E2E の CI 化 | v0.1 運用 1 ヶ月後のフィードバック |
| v0.3 | （展望）複数クラスタ（ネームスペース化された client 集合）、リトライポリシー | — |

v0.1 の milestone 分割（開発セッション向けのタスク単位目安）:

1. M0 — gem 骨子: gemspec / Gemfile / Rakefile / version / require 構造（rspec が回せる状態）
2. M1 — Configuration + reset!（K1 橋渡しを含む Client 実装、例外変換）
3. M2 — CRD 宣言 DSL + Resource（list / find / find_or_nil / create / patch、readonly 制限）
4. M3 — 計測 + README + rubocop 設定
5. M4 — consumer app 移行と検証（§12）

## 11. 展望・検討事項（v0.1 では確定しない）

- **watch**: kruby の watch はストリーム処理であり、Rails のリクエスト応答型には不向き。
  導入するなら「watch 開始 → メッセージをキュー / NotificationCenter 相当に流す」の
  形で、ポーリング置き換えのユースケース（consumer app ダッシュボードの 30 秒ポーリング）から設計する。
- **複数クラスタ**: `KubeRails.cluster("prod") { ... }` のような名前付き client 集合。
  現時点で需要がないため v0.1 では単一クラスタ。
- **retries / timeout**: kruby の `Kubernetes::Configuration` には接続タイムアウトが
  設定できる。v0.1 は既定値 + README 記載のみで、gem 独自のバックオフは持たない
  （Rails 側の middleware / sidekiq retry で吸収するのが慣習）。
- **OpenTelemetry**: `instrumentation` を notification 経由にしているため、
  OTel instrumentation を別途足せる状態に留める（v0.1 で実装しない）。

## 12. consumer app への移行（v0.1 検証）

consumer app の `app/services/k8s_service.rb`（168 行）を `kuberails` に置き換える:

1. `Gemfile` に `gem "kuberails", path: "../kuberails"`（開発期間限定）
2. initializer に CRD 宣言（Workflow / CronWorkflow / crawl-progress の 3 種、
   `readonly: false`（M3 操作系が既にあるため））
3. `consumer app 側の K8s service` 内を `KubeRails.client` 呼び出しに置換。**整形メソッド
   （workflow_summary / crawl_progress_summary / summarize_steps）は consumer app 側に残す**
   （アプリ固有の表示ロジックのため、gem には載せない）
4. 例外: consumer app の `consumer app 側の Unavailable 例外` は `KubeRails::Unavailable` に alias/
   rescue 統一
5. 検証: `make test`（consumer app 側）+ ダッシュボードの K8s 読取が KUBECONFIG 経由で
   従来通り表示されること（実クラスタ への手動確認）

移行後も `consumer app 側の K8s service` を**整形ラッパーとして残す**（コントローラの呼び出し先を変えない、
PR の差分を最小化）。

## 13. 命名・公開

- **gem 名 / リポジトリ名: `kuberails`**（RubyGems で空きを確認済み 2026-09-15。
  `kube-rails` は 2015 年の旧 gem が取得済みであり使用不可）
- GitHub: `doridoridoriand/kuberails`（org `kuberails` は他者が使用済み。個人アカウント配下）
- 公開は v0.1 完成後、**タグ基準の GitHub Actions 公開**（`.github/workflows/publish.yml`）。
  - タグ `v*` push で `gem build` + `gem push`（RubyGems）を自動実行。
    タグ名と gemspec の `VERSION` の不一致は CI で検出して失敗させる
  - 公開権限はリポジトリ Secrets `GEM_HOST_API_KEY`（RubyGems API key）。
    初回は RubyGems アカウント作成 + `gem owner kuberails <username>` を owner が実施
  - テスト CI（`.github/workflows/test.yml`）は push / PR 時に rspec + rubocop を実行。
    テストはクラスタ不要（§9・スタブ注入）のため v0.1 は runner 上のユニットのみ。
    kind / 実クラスタ E2E の CI 化は v0.2 対象（§9・§10）
- `README` に「kruby pin」「対応 k8s バージョン（実測 v1.33.x で検証済み）」「K1 橋渡しの背景」
  を明記する（検索でヒットする重要な注意点のため）

## 14. 承認・変更履歴

| 版 | 日付 | 変更 | 承認 |
|---|---|---|---|
| 0.1 | 2026-09-15 | 初版（案）。consumer app consumer app 側の K8s service の知見 K1–K5 を基に作成 | 未承認 |
| 0.1.1 | 2026-09-18 | PR #1 レビュー対応: 文字列キー化の純 Ruby 経路（ActiveSupport 非依存）、401/403→ApiError 統一、`throw`→`raise`、core v1 を built-in 扱いに修正、`~> 1.36.0` に統一、テスト注入の `api_client` 追加、例外ツリーに `ReadOnlyError`/`RedeclarationError` 追記、初期化子例を汎用化 | レビュー反映済み |
| 0.1.2 | 2026-09-18 | M1 実装にあたって kruby 1.36.2.1 を実機確認した差分を反映: `connected?` の endpoint を `VersionApi#get_code`（GET /version/）に修正、転送失敗（DNS/timeout/接続拒否）が `ApiError(code == 0)` として surfacing することを §5.2/§5.4 に明記、文字列キー化を常に `Normalizer`（`deep_stringify_keys` 経路廃止）に統一 | 実装反映済み |
| 0.1.3 | 2026-09-20 | M3 実装に伴う §8 の軽微明確化: notification の `operation` は symbol・`status` は文字列であること、例外は発火後そのまま raise（swallow しない）こと、no-op 時（AS 無 / instrumentation: false）もブロック値がそのまま返ること。加えて `connected?` の戻り値記述を実装に合わせ修正（false を返す経路なし・失敗は raise）、テストスタブのメソッド名を kruby `CustomObjectsApi` 形式（`*_namespaced_custom_object`）に修正 | 実装反映済み |
| 0.1.4 | 2026-09-21 | リリース準備（§13）: 公開導線を手動 `gem push` から**タグ基準の GitHub Actions**（`test.yml` / `publish.yml`）に更新、README に検証済み k8s サーババージョン（v1.33.x / microk8s v1.33.13）を追記、CHANGELOG.md を同梱、gemspec に `source_code_uri` / `changelog_uri` / `allowed_push_host` メタ情報を追加 | 実装反映済み |
