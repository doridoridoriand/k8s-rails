# Change Log

All notable changes to `k8s-rails` are documented in this file.

## Unreleased

- **kubeconfig load failures now surface as `K8sRails::Unavailable`** (#30):
  `Kubernetes::Configuration.default_config` runs before any request, so a
  broken kubeconfig (e.g. a `current-context` that does not exist) leaked the
  raw `Kubernetes::ConfigError` out of `K8sRails.client` / `K8sRails.connected?`.
  The config-resolution stage (`Client.build_configuration`) now applies the
  same conversion as the transport-time path — `Unavailable` with the original
  `Kubernetes::ConfigError` preserved as `#cause` — for both `Resource.list`
  and `connected?`. The rescue is narrow (`ConfigError` only), so programming
  errors still propagate unconverted.

- **`find` / `patch` / `delete` (and `*_cluster`) reject invalid target names
  before any request is issued** (#28): `nil`, an empty string, `"."` or
  `".."` raise `ArgumentError`. Previously `delete(nil)` built the
  collection URL, which is a Delete Collection call — an unintended bulk
  delete when the caller has the `deletecollection` permission; `"."` /
  `".."` were normalized away by the HTTP client into a different resource
  path. Gate order is unchanged: scope gate, then readonly gate, then name
  validation (rejected calls are not instrumented).
- **The K1 bearer-token bridge keeps a rotated token fresh** (#29): the
  bridge no longer freezes the first copy of
  `api_key['authorization']` → `api_key['BearerToken']`; it re-syncs on
  every request (kruby calls `auth_settings` per request, which is exactly
  where kruby's in-cluster token-refresh hook runs). Long-running processes
  using an in-cluster ServiceAccount token now pick up rotated tokens
  without rebuilding the client. The token sent by a request is taken from
  the value refreshed on that same call and is never re-read from the
  shared configuration afterwards, so concurrent requests in a threaded
  process cannot send a stale copy. A `BearerToken` set explicitly by the
  application is never bridged or overwritten: before client creation the
  bridge is not installed, and if the app replaces the value after the
  client exists (explicit credential rotation), the bridge stops syncing
  and the app's value stays authoritative.
- **`k8s-rails.request` notifications now use the standard ActiveSupport block
  form** (#32): the API call runs inside
  `ActiveSupport::Notifications.instrument`, so the standard start/finish
  times bracket the real processing
  (`ActiveSupport::Notifications::Event#duration` now reports the actual call
  duration — previously the event was emitted after the call, so the standard
  duration was ~0) and failures carry the standard
  `exception` / `exception_object` metadata. The custom §8 payload
  (`operation` / resource coordinates / `duration_ms` / closed `status` enum)
  and the no-op / return-value contracts are unchanged; `status` and
  `duration_ms` are set in the block's `ensure`, so the finish event payload
  always carries them and the original exception is still re-raised.

## 0.3.1

- **Gemspec wording sync (RubyGems page text update)**: `summary` / `description`
  updated to match the v0.3.0 scope (PR #25). Published gem text cannot be
  changed after push, so publishing 0.3.1 switches the RubyGems page to the new
  wording ("Kubernetes API access convention layer for Rails applications").
  **No code or behavior change.**

## 0.3.0

- **Expanded resource support: core v1 built-ins (Pod / Service / ConfigMap /
  Node, etc.) are now supported.** Previously the transport relied on kruby's
  `CustomObjectsApi` (fixed `/apis/{group}/...` paths), so core v1 resources
  with `group: ""` (`/api/v1/...`) could not be reached (404), while named
  built-ins worked all along. The transport was rewritten as a **unified REST
  layer** on `Kubernetes::ApiClient#call_api`, reaching core v1 / named
  built-in / CRD alike by building the path from the declaration coordinates.
  Existing named built-in and CRD declarations behave exactly as before.
- **Added `delete` / `delete_cluster`** (completing CRUD). The readonly gate is
  the same shape as create / patch (calling with a `readonly: true` declaration
  raises `ReadOnlyError`). K8s returns a Status object
  (`{"kind":"Status","status":"Success"}`) on successful delete.
- **Test injection stub contract change (affects test code)**: the method
  `config.api_client` must implement is now the single
  `call_api(http_method, path, opts)` (returning `[data, status_code, headers]`,
  http_method being `:GET` / `:POST` / `:PATCH` / `:DELETE`), unified from the
  8 CustomObjectsApi methods. Existing stubs need to be replaced with
  `call_api` (production code talking to a real cluster is unaffected).
- Added `:delete` to the `operation` of the `k8s-rails.request` notification.
- E2E-verified on a real cluster (microk8s v1.33.13): Pod list / Deployment
  find / ConfigMap create/patch/delete / Node list_cluster.

## 0.2.1

- **Declared support for Ruby 3.5 / 4.0** (declaration range widened only — no
  code or behavior change): on 2026-09-22, the full rspec / rubocop suite ran
  green on Ruby 4.0.7 (stable, v4.0.7, released 2026-09-15) and
  Ruby 3.5.0-preview1 (the only released 3.5 build) (kruby 1.36.4.1
  installed and verified on both), so `required_ruby_version` was widened from
  `>= 3.3, < 4.0` to **`>= 3.3, < 4.1`**. The upper bound is set to the
  verified 4.0 series, and the CI matrix covers 3.3.0 / 3.3.8 / 3.4.10 /
  3.5.0-preview1 / 4.0.7 — every released Ruby in the range (declared range =
  tested range). Design doc KBR-DESIGN-001 updated to v0.1.13 (draft)
  (§6 / §10 / §13 / §14).

## 0.2.0

- **Cluster-scoped CRD support** (#17): `K8sRails.crd` gains
  `scope: :namespaced` (default) / `:cluster`. Cluster-scoped CRDs
  (ClusterIssuer, etc.) are declared with `scope: :cluster` (must not be
  combined with `namespace:`) and used via `list_cluster` / `find_cluster` /
  `find_or_nil_cluster` / `create_cluster` / `patch_cluster`. Scope-asymmetric
  calls (`*_cluster` on a namespaced declaration / plain methods on a cluster
  declaration) raise `ArgumentError`. The transport now also uses kruby's
  4 `*_cluster_custom_object` methods.
- **Atomic contract for `configure`** (#16): "only once" holds only when the
  block finishes normally. If the block terminates abnormally (any exception —
  including `LoadError` / `ScriptError` — / `throw` / non-local return, etc.),
  the configured flag is reset and a subsequent `configure` runs as usual.
  Attributes written before the abnormal exit remain (the re-run block is
  responsible for setting all attributes it depends on; no rollback is
  performed).
- **Injection contract for `connected?`** (#18): when `config.api_client` is
  injected, it returns `true` without I/O (the injected transport IS the
  connection surface). Without injection, the VersionApi probe runs as before.
- **Connection lookup order fix** (#19): the documented auto-detection order in
  README / design doc / config comments was corrected to kruby 1.36.x's loader
  implementation order (**KUBECONFIG → `~/.kube/config` → in-cluster**,
  in-cluster LAST; the previous "in-cluster → KUBECONFIG" wording was wrong).
  A re-verification procedure for kruby upgrades was added to design doc §7.
- Test injection stub (`config.api_client`) contract: 4 namespaced methods +
  4 cluster methods (the 4 namespaced methods suffice if only namespaced
  declarations are used).
- Design doc KBR-DESIGN-001 updated to v0.1.12 (draft) (§5.1 / §5.2 / §5.3 /
  §6 / §7 / §9 / §14).

## 0.1.0

- **M0**: gem skeleton (gemspec / Gemfile / Rakefile / version / require layout)
- **M1**: Configuration + Client (lazy connect, K1 BearerToken bridging),
  exception hierarchy (`Unavailable` / `NotFound` / `ApiError` +
  `ReadOnlyError` / `RedeclarationError`)
- **M2**: CRD declaration DSL + Resource (`list` / `find` / `find_or_nil` /
  `create` / `patch`; `readonly` is an explicit boolean; re-declaration raises
  `RedeclarationError`)
- **M3**: instrumentation (via ActiveSupport::Notifications, no-op when
  disabled) + README + rubocop
- **M4**: verified in a consumer Rails app's K8s service migration (real
  cluster, microk8s v1.33.13)
- Responses are always string-keyed (K2); pure-Ruby `Normalizer` (no
  ActiveSupport dependency)
- Supported Ruby: `>= 3.3, < 4.0` (floor from kruby 1.36.x's `>= 3.3`; the
  upper bound excludes unverified Ruby 4.x. 4.0 / 3.5 support to be verified
  and declared in v0.2+). CI (GitHub Actions) matrix over 3.3.0 / 3.3.8 / 3.4.10
- Supported Kubernetes server: verified on v1.33.x against a real cluster (see
  README)
- Publishing path: manual `gem push` from the owner's local PC (after rake
  fully green + CHANGELOG finalized; no CI auto-publish)
