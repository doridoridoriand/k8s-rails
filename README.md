# kuberails

> A Kubernetes API / CRD convention layer for Rails applications.

`kuberails` provides the **connection, CRD access, and error-handling convention
layer** for Rails applications that talk to the Kubernetes API.

[![Test](https://github.com/doridoridoriand/kuberails/actions/workflows/test.yml/badge.svg)](https://github.com/doridoridoriand/kuberails/actions/workflows/test.yml)
[![Gem Version](https://badge.fury.io/rb/kuberails.svg)](https://rubygems.org/gems/kuberails)

For the design rationale, see the [design document (docs/design.md)](docs/design.md) (KBR-DESIGN-001).

## Requirements

| Item | Supported range | Notes |
|------|-----------------|-------|
| Ruby | `>= 3.3, < 4.0` | Floor: kruby 1.36.x requires Ruby 3.3. Upper bound: unverified Ruby 4.x is excluded from the declared range. CI verifies the declared range with a 3.3.0 / 3.3.8 / 3.4.10 matrix |
| kruby | `~> 1.36.0` | The official Kubernetes OpenAPI client |
| Kubernetes server | **Verified on v1.33.x** (a real cluster, microk8s v1.33.13, 2026-09-21) | kruby 1.36.x is a 1.36-series client. Newer servers (1.36, etc.) use the same API (CustomObjects API v1), so compatibility is expected, but has not yet been verified against a real cluster |
| Dependencies | **kruby only** at runtime | ActiveSupport is used only for optional [instrumentation](#instrumentation-optional-activesupport) (no-op when absent) |

## Installation

```ruby
# Gemfile
gem "kuberails", "~> 0.1"
```

```ruby
require "kuberails"
KubeRails::VERSION # => "0.1.0"
```

`require` is side-effect-free and needs no cluster. kruby itself is loaded
lazily on the first `KubeRails.client` / `KubeRails.connected?` / CRD operation
(**lazy connect**), so the gem can be required even when no cluster is
reachable.

## Quick start

```ruby
# config/initializers/kuberails.rb
KubeRails.configure do |config|
  config.namespace = "team-a" # default namespace (can be overridden per declaration or per call)
end

# Declare the CRD you work with (group / version / plural / kind are never guessed)
Workflow = KubeRails.crd(
  group:  "argoproj.io",
  version: "v1alpha1",
  plural: "workflows",
  kind:   "Workflow",
  readonly: false, # default true; false enables create/patch
)
```

```ruby
Workflow.list                 # => [{"name" => "...", "labels" => {...}}, ...]
Workflow.find("wf-1")         # same shape / raises KubeRails::NotFound when absent
Workflow.find_or_nil("wf-1")  # same, but returns nil instead of raising
Workflow.create({ metadata: { name: "wf-1" } })                     # readonly: false only
Workflow.patch("wf-1", [{ op: "replace", path: "/spec/a", value: 2 }]) # readonly: false only

KubeRails.connected?          # true on success; raises on failure
```

## Configuration

```ruby
KubeRails.configure do |config|
  config.namespace = "team-a"          # default namespace (default: "default")
  # config.connection = my_config      # pass a Kubernetes::Configuration directly (optional)
  # config.instrumentation = false     # disable instrumentation (default true; only effective when ActiveSupport is present)
  # config.api_client = stub           # test-only: inject a transport (see [Testing](#testing))
end
```

- `configure` is effective **only once**. A second call prints a warning and is
  ignored (use `KubeRails.reset!` to reset the configuration, the cached
  transport, and declared CRDs — primarily for tests).
- Connection resolution order: `config.api_client` (test injection) →
  `config.connection` → `Kubernetes::Configuration.default_config`
  (automatic in-cluster → KUBECONFIG detection).

## CRD declaration and access

`plural` / `kind` are **never guessed** (many CRDs do not follow the obvious
naming convention). Re-declaring the same kind raises
`KubeRails::RedeclarationError` (configuration-mistake detection).

Return values are **always string-keyed hashes**. kruby returns symbol keys,
but Rails-side JSON/views work with string keys, so the gem normalizes
internally in pure Ruby (no ActiveSupport dependency). Every method accepts a
`namespace:` argument to override the namespace from the declaration.

`readonly` must be an **explicit boolean** (`nil` or other values raise
`ArgumentError`). Writes are enabled **only** by `readonly: false`, so a
missing flag can never fail open.

## Connectivity check

```ruby
KubeRails.connected?  # true on success; raises KubeRails::Unavailable / ApiError on failure
                      # a lightweight /version-equivalent check
```

It never returns `false` — a connection failure surfaces as an exception
(handle it with `rescue`). The actual API connection is established lazily on
the first API call.

## Exception hierarchy

```
KubeRails::Error < StandardError
├── KubeRails::Unavailable   # transport-layer failure (DNS/timeout/connection refused; kruby 1.36.x reports it as ApiError code 0)
├── KubeRails::NotFound      # HTTP 404
├── KubeRails::ApiError      # other API errors (401/403/409/422/5xx); holds #code and #response
├── KubeRails::ReadOnlyError      # create/patch called on a readonly: true declaration
└── KubeRails::RedeclarationError # re-declaration of an already-declared CRD kind
```

Recommended caller pattern:

```ruby
begin
  Workflow.list
rescue KubeRails::Unavailable
  # cluster-side problem → "unable to load" fallback UI, etc.
rescue KubeRails::ApiError => e
  # inspect e.code / e.response to determine the cause
end
```

## Instrumentation (optional ActiveSupport)

When `config.instrumentation = true` (the default) and ActiveSupport is loaded,
each API call is published as a `kuberails.request` notification (no-op when
ActiveSupport is absent):

```
kuberails.request
  payload: { operation:, group:, version:, plural:, namespace:, duration_ms:,
             status: "ok" | "unavailable" | "api_error" }
```

In a Rails app you can subscribe with `ActiveSupport::Notifications`:

```ruby
ActiveSupport::Notifications.subscribe("kuberails.request") do |name, start, finish, id, payload|
  Rails.logger.info("[kuberails] #{payload[:operation]} #{payload[:plural]} (#{payload[:duration_ms]}ms) #{payload[:status]}")
end
```

## Testing

The test suite needs **no cluster**. Tests inject a transport stub via
`config.api_client`. The stub is wrapped internally by an adapter, so it just
implements the same four methods as kruby's `CustomObjectsApi`:

```ruby
class StubTransport
  def list_namespaced_custom_object(group, version, namespace, plural) = { items: [] }
  def get_namespaced_custom_object(group, version, namespace, plural, name) = {}
  def create_namespaced_custom_object(group, version, namespace, plural, body) = {}
  def patch_namespaced_custom_object(group, version, namespace, plural, name, body) = {}
end

KubeRails.configure { |c| c.api_client = StubTransport.new }
```

## Development

```
bundle install
bundle exec rake   # rspec + rubocop
```

## Known issue: kruby 1.36 bearer-token key mismatch

kruby 1.36.x's in-cluster / KUBECONFIG configuration writes the bearer token
to `api_key['authorization']`, but `Configuration#auth_settings` reads
`api_key['BearerToken']` for the `Authorization` header. Because the keys do
not match, **the Authorization header ends up empty and requests fail with
401** when using kruby's configuration directly.

kuberails automatically copies `authorization` to `BearerToken` when building
its client (the design document calls this the "K1 bridge"), so connections
through kuberails are unaffected (it does not overwrite an already-set
`BearerToken`). If you see 401s from a cluster connection that relies on
kruby's own configuration behavior (outside this gem), check this token-key
issue first.

## Roadmap (v0.2+)

- Ruby 3.5 / 4.0 support (after verifying against the stable releases, then
  widening the declared range and the CI matrix)
- CI-based E2E tests using kind
- watch (streaming) support, under consideration

## License

MIT ([LICENSE](LICENSE))
