# Change Log

`k8s-rails` の全 notable な変更はこのファイルに記録する。

## Unreleased

- **対応リソースの拡大: core v1 built-in（Pod / Service / ConfigMap / Node 等）に対応**。
  従来、transport は kruby の `CustomObjectsApi`（`/apis/{group}/...` 固定パス）
  に依存しており、`group: ""` の core v1 リソース（`/api/v1/...`）だけは 404
  で到達できなかった（named built-in は従来から動作）。transport を
  `Kubernetes::ApiClient#call_api` 上の**統一 REST 層**に改訂し、
  core v1 / named built-in / CRD の全てを宣言座標からのパス構築で到達させる。
  named 系・CRD の既存宣言の挙動は不変。
- **`delete` / `delete_cluster` を追加**（CRUD 完成）。readonly ゲートは
  create / patch と同型（`readonly: true` 宣言で呼ぶと `ReadOnlyError`）。
  K8s は削除成功時に Status オブジェクト（`{"kind":"Status","status":"Success"}`）を返す。
- **テスト注入スタブの契約変更（テストコードへの影響）**: `config.api_client`
  が実装すべきメソッドは CustomObjectsApi の 8 メソッドから
  `call_api(http_method, path, opts)` の 1 メソッドに統一
  （戻り値 `[data, status_code, headers]`、http_method は
  `:GET` / `:POST` / `:PATCH` / `:DELETE`）。既存スタブは `call_api` に
  置き換える必要がある（実クラスタ接続の production コードには影響なし）。
- `k8s-rails.request` notification の `operation` に `:delete` を追加。
- 実クラスタ（microk8s v1.33.13）で Pod list / Deployment find /
  ConfigMap create・patch・delete / Node list_cluster を E2E 検証済み。

## 0.2.1

- **Ruby 3.5 / 4.0 対応の宣言**（宣言範囲拡大のみ・コード・挙動変更なし）:
  2026-09-22 に Ruby 4.0.7（stable・v4.0.7、2026-09-15 リリース）と
  Ruby 3.5.0-preview1（3.5 系で公開済みの唯一のリリース）で全
  rspec / rubocop を実行し緑を確認したため（kruby 1.36.4.1 は両方で
  install / 動作確認）、`required_ruby_version` を `>= 3.3, < 4.0` から
  **`>= 3.3, < 4.1`** に拡大。上限は検証済みの 4.0 系に設定し、
  CI matrix は 3.3.0 / 3.3.8 / 3.4.10 / 3.5.0-preview1 / 4.0.7 の 5 系統で
  範囲内の公開済み Ruby を全カバー（宣言範囲 = 検証範囲）。
  設計書 KBR-DESIGN-001 v0.1.13（案）へ更新（§6 / §10 / §13 / §14）。

## 0.2.0

- **cluster-scoped CRD サポート**（#17）: `K8sRails.crd` に `scope: :namespaced`
  （既定）/ `:cluster` を追加。cluster-scoped CRD（ClusterIssuer 等）は
  `scope: :cluster`（`namespace:` 併用不可）で宣言し、`list_cluster` /
  `find_cluster` / `find_or_nil_cluster` / `create_cluster` /
  `patch_cluster` を使う。スコープと非対称な呼び出し（namespaced 宣言で
  `*_cluster` / cluster 宣言で素のメソッド）は `ArgumentError`。
  transport は kruby の `*_cluster_custom_object` 4 メソッドを新たに利用。
- **`configure` のアトミック契約**（#16）: 「一度だけ」はブロックが
  正常終了した場合のみ成立。ブロックが異常終了した（任意の例外 —
  `LoadError` / `ScriptError` を含む — / `throw` / non-local return 等）
  場合は設定済みフラグがリセットされ、後続の `configure` は通常どおり
  実行される。異常終了前に書き込まれた属性は残存する（再実行ブロックは
  依存する属性を全て設定する責務を負う。ロールバックはしない）。
- **`connected?` の注入契約**（#18）: `config.api_client` 注入時は
  I/O なしで `true`（注入トランスポートが接続面そのもの）。
  非注入時は従来どおり VersionApi プローブ。
- **接続設定探索順序の修正**（#19）: README / 設計書 / 設定コメントの
  自動検出順序を kruby 1.36.x の loader 実装順
  （**KUBECONFIG → `~/.kube/config` → in-cluster**、in-cluster は最後）
  に修正（従来の「in-cluster → KUBECONFIG」記述は誤り）。kruby 上げ替え
  時の再確認手順を設計書 §7 に追加。
- テスト注入スタブ（`config.api_client`）の契約: namespaced 4 メソッド ＋
  cluster 4 メソッド（namespaced 宣言のみ使う場合は前者 4 メソッドで足りる）。
- 設計書 KBR-DESIGN-001 v0.1.12（案）へ更新（§5.1 / §5.2 / §5.3 / §6 /
  §7 / §9 / §14）。

## 0.1.0

- **M0**: gem 骨子（gemspec / Gemfile / Rakefile / version / require 構造）
- **M1**: Configuration + Client（lazy connect・K1 BearerToken 橋渡し）・例外体系
  （`Unavailable` / `NotFound` / `ApiError` + `ReadOnlyError` / `RedeclarationError`）
- **M2**: CRD 宣言 DSL + Resource（`list` / `find` / `find_or_nil` / `create` / `patch`、
  `readonly` は明示 boolean、再宣言は `RedeclarationError`）
- **M3**: 計測（ActiveSupport::Notifications 経由、無効時 no-op）+ README + rubocop
- **M4**: consumer Rails アプリの K8s サービス移行で動作検証
  （実クラスタ microk8s v1.33.13）
- 応答は常に文字列キー（K2）・純 Ruby `Normalizer`（ActiveSupport 非依存）
- 対応 Ruby: `>= 3.3, < 4.0`（下限は kruby 1.36.x の `>= 3.3`。上限は
  未検証の Ruby 4.x を宣言から除外するため。4.0 / 3.5 対応は v0.2 以降
  で検証の上宣言に含める）。
  CI（GitHub Actions）で 3.3.0 / 3.3.8 / 3.4.10 の matrix 検証
- 対応 Kubernetes サーバ: v1.33.x で実クラスタ検証済み（README 参照）
- 公開導線: owner のローカル PC から手動 `gem push`（rake 全緑確認 +
  CHANGELOG 確定後に実施。CI の自動公開は行わない）
