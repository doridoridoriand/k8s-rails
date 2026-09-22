# k8s-rails
A Kubernetes API access convention layer for Rails applications.

`k8s-rails` provides the **connection, resource access, and error-handling
convention layer** for Rails applications that talk to the Kubernetes API. It
covers every resource kruby can address: **core v1** built-ins (Pod, Service,
ConfigMap, ...), **named-group** built-ins (Deployment, Ingress, ...), and
**CRDs**.

[![Test](https://github.com/doridoridoriand/k8s-rails/actions/workflows/test.yml/badge.svg)](https://github.com/doridoridoriand/k8s-rails/actions/workflows/test.yml)
[![Gem Version](https://badge.fury.io/rb/k8s-rails.svg)](https://rubygems.org/gems/k8s-rails)

For the design rationale, see the [design document (docs/design.md)](docs/design.md) (KBR-DESIGN-001).

## Requirements

| Item | Supported range | Notes |
|------|-----------------|-------|
| Ruby | `>= 3.3, < 4.1` | Floor: kruby 1.36.x requires Ruby 3.3. Ruby 4.0 support verified on Ruby 4.0.7 (2026-09-22); Ruby 3.5 verified on 3.5.0-preview1 (the only released 3.5, 2026-09-22). CI verifies the declared range with a 3.3.0 / 3.3.8 / 3.4.10 / 3.5.0-preview1 / 4.0.7 matrix — every released Ruby in the range |
| kruby | `~> 1.36.0` | The official Kubernetes OpenAPI client |
| Kubernetes server | **Verified on v1.33.x** (real cluster, microk8s v1.33.13, 2026-09-21) | The transport speaks the generic Kubernetes REST API, so newer servers (1.36, etc.) are expected to work but are not yet verified on a real cluster |
| Dependencies | **kruby only** at runtime | ActiveSupport is used only for optional [instrumentation](#instrumentation-optional-activesupport) (no-op when absent) |

## Installation

```ruby
# Gemfile
gem "k8s-rails", "~> 0.2"
```

```ruby
require "k8s-rails"
K8sRails::VERSION # => "0.2.1"
```

`require` is side-effect-free and needs no cluster. kruby itself is loaded
lazily on the first `K8sRails.client` / `K8sRails.connected?` / CRD operation
(**lazy connect**), so the gem can be required even when no cluster is
reachable.

## Quick start

`k8s-rails` reaches **every resource the Kubernetes API exposes** — core v1
built-ins (Pod, Service, ConfigMap, ...), named-group built-ins (Deployment,
Ingress, ...), and CRDs — through one declaration API. The transport speaks
the generic REST API: a core v1 resource is declared with an **empty group**
(`group: ""` → `/api/v1/...`), any other resource with its API group
(`/apis/{group}/{version}/...`).

### 1. Configure (once, in an initializer)

```ruby
# config/initializers/k8s-rails.rb
K8sRails.configure do |config|
  config.namespace = "team-a" # default namespace (can be overridden per declaration or per call)
end
```

### 2. Declare the resource you work with

Coordinates are declared explicitly — group / version / plural / kind are
**never guessed**. A core v1 resource (Pods) uses an empty group:

```ruby
Pod = K8sRails.crd(
  group:  "",            # core v1 (the "/api/v1" API group)
  version: "v1",
  plural: "pods",
  kind:   "Pod",
  readonly: false, # default true; only an explicit false enables create/patch/delete
)
```

A named-group built-in (Deployments) is identical except for the group:

```ruby
Deployment = K8sRails.crd(
  group:  "apps",        # "/apis/apps/v1"
  version: "v1",
  plural: "deployments",
  kind:   "Deployment",
)
```

### 3. Read and write (CRUD)

All return values are string-keyed hashes:

```ruby
Pod.list                      # => [{"metadata" => {"name" => "..."}, "spec" => {...}}, ...]
Pod.find("api-7d9f8b6c5-xk2lt")   # the full object; raises K8sRails::NotFound when absent
Pod.find_or_nil("missing")   # same, but returns nil instead of raising

# readonly: false only
Pod.create({
  apiVersion: "v1",
  kind:       "Pod",
  metadata:   { name: "busybox" },
  spec:       { containers: [{ name: "busybox", image: "busybox" }] }
})
Pod.patch("busybox", [{ op: "replace", path: "/spec/containers/0/image", value: "busybox:1.36" }])
Pod.delete("busybox")        # => {"kind" => "Status", "status" => "Success", ...}

# Deployment (named group) is used exactly the same way
Deployment.list              # all Deployments in the default namespace
Deployment.find("web")
Deployment.delete("web")     # readonly: false only

K8sRails.connected?          # true on success; raises K8sRails::Unavailable / ApiError on failure
```

### Example: Argo Workflows (CRD)

The same declaration and operations work for any CRD — here, the Argo
Workflows `Workflow` CRD:

```ruby
Workflow = K8sRails.crd(
  group:  "argoproj.io",
  version: "v1alpha1",
  plural: "workflows",
  kind:   "Workflow",
  readonly: false, # default true; false enables create/patch/delete
)

Workflow.list                 # => [{"metadata" => {"name" => "...", ...}}, ...]
Workflow.find("wf-1")         # same shape / raises K8sRails::NotFound when absent
Workflow.find_or_nil("wf-1")  # same, but returns nil instead of raising
Workflow.create({ metadata: { name: "wf-1" } })                     # readonly: false only
Workflow.patch("wf-1", [{ op: "replace", path: "/spec/a", value: 2 }]) # readonly: false only
Workflow.delete("wf-1")                                            # readonly: false only
```

## Configuration

```ruby
K8sRails.configure do |config|
  config.namespace = "team-a"          # default namespace (default: "default")
  # config.connection = my_config      # pass a Kubernetes::Configuration directly (optional)
  # config.instrumentation = false     # disable instrumentation (default true; only effective when ActiveSupport is present)
  # config.api_client = stub           # test-only: inject a transport (see [Testing](#testing))
end
```

- `configure` is effective **only once** — but only when the block returns
  normally. If the block exits abnormally (any exception, including
  `LoadError`; `throw`; non-local return), the "configured" flag is reset,
  so a later `configure` runs normally. Note that attribute writes made
  before the abnormal exit **remain** on the shared configuration (a
  partially applied state is possible); a re-run block should set every
  attribute it depends on.
  A second call on an already-configured gem prints a warning and is ignored
  (use `K8sRails.reset!` to reset the configuration, the cached transport, and
  declared CRDs — primarily for tests).
- Connection resolution order: `config.api_client` (test injection) →
  `config.connection` → `Kubernetes::Configuration.default_config`
  (automatic detection in kruby 1.36.x: `KUBECONFIG` → `~/.kube/config` →
  in-cluster. Note in-cluster is tried **last**, after the file-based
  sources — re-verify `kruby`'s loader when upgrading kruby).

## Resource declaration and access

The same `K8sRails.crd` API covers core v1 built-ins, named-group built-ins,
and CRDs. `plural` / `kind` are **never guessed** (many resources do not
follow the obvious naming convention). Re-declaring the same kind raises
`K8sRails::RedeclarationError` (configuration-mistake detection).

- **core v1** resources (Pod, Service, ConfigMap, ...): `group: ""`
- **named-group** resources (Deployment = `apps`, Ingress = `networking.k8s.io`,
  any CRD group): the resource's API group
- **cluster-scoped** resources (Node, ClusterIssuer, ...): `scope: :cluster`
  and no `namespace:` (see [Cluster-scoped resources](#cluster-scoped-resources))

Return values are **always string-keyed hashes**. kruby returns symbol keys,
but Rails-side JSON/views work with string keys, so the gem normalizes
internally in pure Ruby (no ActiveSupport dependency). Every namespaced
method accepts a `namespace:` argument to override the namespace from the
declaration (the `*_cluster` methods take no `namespace:`).

`readonly` must be an **explicit boolean** (`nil` or other values raise
`ArgumentError`). Writes (`create` / `patch` / `delete`) are enabled **only**
by `readonly: false`, so a missing flag can never fail open.

### Cluster-scoped resources

Both namespaced and cluster-scoped resources are supported. Declare a
cluster-scoped resource (Node, ClusterIssuer, ClusterWorkflowTemplate, ...)
with `scope: :cluster` and **without** `namespace:` (combining the two raises
`ArgumentError`):

```ruby
ClusterIssuer = K8sRails.crd(
  group:  "cert-manager.io",
  version: "v1",
  plural: "clusterissuers",
  kind:   "ClusterIssuer",
  scope:  :cluster,          # cluster-scoped endpoints (no namespace)
)

ClusterIssuer.list_cluster               # all objects cluster-wide
ClusterIssuer.find_cluster("letsencrypt")
ClusterIssuer.find_or_nil_cluster("x")
ClusterIssuer.create_cluster({ ... })    # readonly: false only
ClusterIssuer.patch_cluster("letsencrypt", [{ ... }])  # readonly: false only
ClusterIssuer.delete_cluster("letsencrypt")            # readonly: false only
```

Core v1 has cluster-scoped resources too (Node, Namespace):

```ruby
Node = K8sRails.crd(group: "", version: "v1", plural: "nodes", kind: "Node", scope: :cluster)
Node.list_cluster        # all nodes
Node.find_cluster("n1")
```

On a `scope: :namespaced` declaration (the default) the `*_cluster` methods
raise `ArgumentError` — the resource is namespaced, so the cluster endpoints
would 404 anyway. For a cluster-scoped declaration, use the `*_cluster`
methods (the plain `list`/`find`/... would call the namespaced endpoints and
404, so they raise `ArgumentError` there as well).

## Connectivity check

```ruby
K8sRails.connected?  # true on success; raises K8sRails::Unavailable / ApiError on failure
                      # a lightweight /version-equivalent check
```

It never returns `false` — a connection failure surfaces as an exception
(handle it with `rescue`). The actual API connection is established lazily on
the first API call.

When a test transport is injected via `config.api_client`, `connected?`
returns `true` without any network I/O — the injected transport **is** the
connection surface, so probing a real endpoint would contradict the Resource
operations that the same injection serves.

## Exception hierarchy

```
K8sRails::Error < StandardError
├── K8sRails::Unavailable   # transport-layer failure (DNS/timeout/connection refused; kruby 1.36.x reports it as ApiError code 0)
├── K8sRails::NotFound      # HTTP 404
├── K8sRails::ApiError      # other API errors (401/403/409/422/5xx); holds #code and #response
├── K8sRails::ReadOnlyError      # create/patch/delete called on a readonly: true declaration
└── K8sRails::RedeclarationError # re-declaration of an already-declared kind
```

Recommended caller pattern:

```ruby
begin
  Workflow.list
rescue K8sRails::Unavailable
  # cluster-side problem → "unable to load" fallback UI, etc.
rescue K8sRails::ApiError => e
  # inspect e.code / e.response to determine the cause
end
```

## Instrumentation (optional ActiveSupport)

When `config.instrumentation = true` (the default) and ActiveSupport is loaded,
each API call is published as a `k8s-rails.request` notification (no-op when
ActiveSupport is absent):

```
k8s-rails.request
  payload: { operation:, group:, version:, plural:, namespace:, duration_ms:,
             status: "ok" | "unavailable" | "api_error" }
```

In a Rails app you can subscribe with `ActiveSupport::Notifications`:

```ruby
ActiveSupport::Notifications.subscribe("k8s-rails.request") do |name, start, finish, id, payload|
  Rails.logger.info("[k8s-rails] #{payload[:operation]} #{payload[:plural]} (#{payload[:duration_ms]}ms) #{payload[:status]}")
end
```

## Testing

The test suite needs **no cluster**. Tests inject a transport stub via
`config.api_client`. The transport speaks kruby's `Kubernetes::ApiClient#call_api`
protocol, so a stub just implements that one method — `call_api(http_method,
path, opts)` returning `[data, status_code, headers]`. `http_method` is one of
`:GET` / `:POST` / `:PATCH` / `:DELETE`, and `path` is the fully-built API
path (the gem builds it from the declaration — core v1 as `/api/v1/...`,
everything else as `/apis/{group}/{version}/...`):

```ruby
class StubTransport
  def call_api(method, path, opts = {})
    case method
    when :GET   then { items: [] }, 200, {}   # ... or a single object
    when :POST  then { metadata: {} }, 200, {}
    when :PATCH then { metadata: {} }, 200, {}
    when :DELETE then { kind: "Status", status: "Success" }, 200, {}
    end
  end
end

K8sRails.configure { |c| c.api_client = StubTransport.new }
```

A realistic stub routes on `path` (and `opts[:body]` for writes). Responses
may use symbol keys — the gem stringifies them.

With a transport injected, `K8sRails.connected?` returns `true` without
network I/O (see [Connectivity check](#connectivity-check)).

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

k8s-rails automatically copies `authorization` to `BearerToken` when building
its client (the design document calls this the "K1 bridge"), so connections
through k8s-rails are unaffected (it does not overwrite an already-set
`BearerToken`). If you see 401s from a cluster connection that relies on
kruby's own configuration behavior (outside this gem), check this token-key
issue first.

## Roadmap (v0.3+)

- Update the CI matrix when Ruby 3.5 reaches a stable release (3.5 is
  verified today on 3.5.0-preview1, the only released 3.5)
- CI-based E2E tests using kind
- watch (streaming) support, under consideration

## License

MIT ([LICENSE](LICENSE))
