# frozen_string_literal: true

# kruby の require は本ファイルにのみ許される（design §7）。
# 他のファイルは kruby の定数・クラスを参照しない。
# Typhoeus は kruby が require するため転送層例外もここに閉じ込める。
require "kubernetes"
require "cgi"

module K8sRails
  # Resolves a connection to the Kubernetes API and exposes the read/write
  # operations as a small internal REST transport (design §5.2 / §7).
  #
  #   api = K8sRails::Client.build
  #   api.list(group, version, namespace, plural)
  #   api.get(group, version, namespace, plural, name)
  #   api.create(group, version, namespace, plural, body)
  #   api.patch(group, version, namespace, plural, name, body)
  #   api.delete(group, version, namespace, plural, name)
  #   # cluster-scoped (namespace argument omitted, design §5.3)
  #   api.list_cluster(group, version, plural)
  #   api.get_cluster(group, version, plural, name)
  #   api.create_cluster(group, version, plural, body)
  #   api.patch_cluster(group, version, plural, name, body)
  #   api.delete_cluster(group, version, plural, name)
  #
  # The transport is a uniform REST layer over kruby's `Kubernetes::ApiClient`
  # (`call_api`), NOT the `CustomObjectsApi`. A single path builder maps the
  # declaration coordinates (group / version / scope / namespace / plural /
  # name) onto the API path, so it reaches EVERY resource kruby can address:
  # core v1 (`group: ""` → `/api/v1/...`), named built-in groups
  # (`apps/v1` → `/apis/apps/v1/...`), and CRDs (`/apis/{group}/{version}/...`).
  #
  # Connection is LAZY: `build` does no network I/O — it only resolves a
  # `Kubernetes::Configuration` and builds an in-memory `ApiClient`. The first
  # real call is where DNS/timeout/TLS can fail.
  class Client
    # Serializes the first connection resolution + transport build (and
    # `reset!`) so a concurrent Resource operation and `connected?` probe
    # cannot resolve DIFFERENT configs (kubeconfig changing between the two
    # resolutions would recreate the #31 probe/operation mismatch in a
    # threaded process — `||=` alone is not atomic). The probe's HTTP I/O
    # runs OUTSIDE the lock: only first-time resolution pays for it.
    BUILD_LOCK = Mutex.new

    class << self
      # Return the shared transport, building it on first call (lazy connect).
      #
      # Resolution order (design §5.2):
      #   0. `config.api_client` (test injection) → used as the transport
      #      directly, connection resolution skipped.
      #   1. `config.connection` if set, else `Kubernetes::Configuration.default_config`
      #   2. K1 bridge: duplicate `api_key['authorization']` into
      #      `api_key['BearerToken']` (kruby 1.36 in-cluster/KUBECONFIG write the
      #      token under 'authorization' but auth_settings reads 'BearerToken'),
      #      and keep the bridge in sync on every `auth_settings` call so a
      #      rotated ServiceAccount token is picked up (#29).
      #   3. Build `ApiClient` (in-memory, no I/O).
      #   4. Wrap in a StringKeyedAdapter that normalizes responses (K2) and
      #      converts kruby errors to K8sRails exceptions.
      def build
        BUILD_LOCK.synchronize do
          @build ||= if (injected = K8sRails.config.api_client)
                       StringKeyedAdapter.new(injected)
                     else
                       StringKeyedAdapter.new(build_api_client)
                     end
        end
      end

      # Lightweight connectivity probe (design §5.2). Performs one lightweight
      # `/version` call via VersionApi and returns true on success. Raises
      # K8sRails::Unavailable / ApiError on failure (the app may rescue).
      #
      # Injection contract: when `config.api_client` is set (test injection),
      # the injected transport IS the connection surface — there is no real
      # network to probe, so this returns true without I/O. This keeps
      # `connected?` consistent with Resource operations under injection
      # (design §5.2).
      def connected?
        return true if K8sRails.config.api_client

        # Resolution + K1 bridge happen under BUILD_LOCK (one critical section
        # with the transport build); only the probe's HTTP I/O stays outside.
        config = BUILD_LOCK.synchronize do
          resolved = resolved_connection_config
          bridge_bearer_token(resolved)
          resolved
        end
        VersionApiProbe.new(config).probe
      end

      # Reset cached connection + transport (test support, §5.1). Also drops
      # the cached resolved config so the next build/probe re-resolves (#31).
      # Takes BUILD_LOCK so a reset cannot interleave with a build.
      def reset!
        BUILD_LOCK.synchronize do
          @build = nil
          @resolved_connection_config = nil
        end
      end

      # Convert a kruby ApiError to the K8sRails exception tree (K3, §5.4).
      #   - code 0 (transport failure: DNS/timeout/connect/TLS) → Unavailable
      #   - code 404 → NotFound
      #   - anything else (401/403/409/422/5xx) → ApiError (keeps code + body)
      def convert_api_error(kruby_error)
        code = kruby_error.code
        return Unavailable.new("K8s に接続できません: #{transport_message(kruby_error)}") if code.zero?
        return NotFound.new("リソースが見つかりません") if code == 404

        ApiError.new(
          code: code,
          response: kruby_error.response_body,
          message: "Kubernetes API エラー (HTTP #{code})"
        )
      end

      private

      # kruby's ApiError#message is "<msg>\nHTTP status code: N". For code 0 the
      # message is the libcurl reason (e.g. "Could not resolve host"). Strip the
      # status-code suffix for a clean Unavailable message.
      def transport_message(kruby_error)
        kruby_error.message.to_s.sub(/\nHTTP status code:.*\z/, "").strip
      end

      # Build a lazy in-memory ApiClient from the resolved configuration.
      # Runs while BUILD_LOCK is held (from `build`) so the transport and the
      # cached config are selected in one critical section.
      def build_api_client
        config = resolved_connection_config
        bridge_bearer_token(config)
        Kubernetes::ApiClient.new(config)
      end

      # The resolved connection config, cached for the lifetime of the cached
      # transport (#31): `connected?` and Resource operations MUST inspect /
      # use the SAME connection — re-resolving the config would let the probe
      # validate connection B while ops still send to connection A. MUST be
      # read/written while holding BUILD_LOCK so a concurrent first build and
      # first probe resolve the config EXACTLY ONCE (review: `||=` alone is
      # not atomic). There is no implicit reload; `reset!` (test support,
      # §5.1) is the explicit reload path. Cached only on success — a failed
      # resolution (e.g. a broken kubeconfig) is re-attempted on the next call.
      def resolved_connection_config
        @resolved_connection_config ||= build_configuration
      end

      # Resolve the connection configuration. The kubeconfig load happens HERE
      # (kruby's default_config reads KUBECONFIG -> ~/.kube/config ->
      # in-cluster, design §5.2), so a broken kubeconfig / missing context
      # surfaces at build time — BEFORE any request. Convert it to the public
      # exception tree with the original error as `cause` (#30), matching the
      # transport-time conversion in StringKeyedAdapter#request /
      # VersionApiProbe#probe. The rescue is deliberately narrow: programming
      # errors must not be swallowed (design §5.4).
      #
      # The resolved configuration is where the HTTP timeout policy is
      # applied (apply_http_timeout), so Resource operations (build_api_client)
      # and the `connected?` probe carry the SAME value (#33).
      def build_configuration
        config = K8sRails.config.connection || Kubernetes::Configuration.default_config
        apply_http_timeout(config)
        config
      rescue Kubernetes::ConfigError => e
        raise Unavailable, "K8s に接続できません: #{e.message}"
      end

      # HTTP timeout policy (design §5.1 / #33). kruby 1.36.x defaults
      # `Configuration#timeout` to 0, which means NO timeout — an
      # unresponsive API would hold a Rails request / job forever. Apply the
      # configured `http_timeout` (K8sRails::Configuration, default 30s) ONLY
      # when the resolved configuration still carries kruby's unset value
      # (0): an explicitly set `config.connection.timeout` (any non-zero
      # value) is never overridden. `http_timeout = 0` opts out entirely and
      # restores kruby's unlimited default — kruby's own `timeout = 0` is
      # indistinguishable from "never set", so it is treated as unset and the
      # opt-out lives on the K8sRails knob instead.
      #
      # Idempotent: after the first application the resolved timeout is
      # non-zero, so later resolutions skip (the value reads as explicit).
      def apply_http_timeout(config)
        requested = K8sRails.config.http_timeout
        validate_http_timeout!(requested)
        return if requested&.zero? || !config.timeout.to_i.zero?

        config.timeout = requested || Configuration::DEFAULT_HTTP_TIMEOUT
      end

      # `http_timeout` accepts nil (built-in default) or a non-negative
      # Integer (0 = opt out, N >= 1 = seconds). Rejecting non-Integers is
      # fail-fast on purpose: a Float like 0.5 would be truncated by
      # typhoeus/libcurl to CURLOPT_TIMEOUT 0 = unlimited — silently
      # recreating the unbounded wait this policy exists to prevent.
      def validate_http_timeout!(value)
        return if value.nil? || (value.is_a?(Integer) && value >= 0)

        raise ArgumentError,
              "http_timeout must be a non-negative Integer or nil (got #{value.inspect})"
      end

      # K1 bridge (kruby 1.36.x quirk): InClusterConfig writes the Bearer token
      # to `api_key['authorization']` (and the KUBECONFIG path can too), but
      # `Configuration#auth_settings` reads `api_key['BearerToken']` for the
      # `Authorization` header. Without the bridge the header is empty → 401.
      #
      # The bridge must NOT freeze the first copy (#29): kruby's in-cluster
      # refresh hook only runs inside `api_key_with_prefix("authorization")`
      # (it re-reads the token file once the refresh deadline passes), and
      # normal header generation never queries that key. So after the initial
      # copy, a module is prepended to the resolved config's singleton class
      # that re-syncs the bridged `BearerToken` from the upstream key on every
      # `auth_settings` call — kruby calls it for every request, so a rotated
      # token reaches the header without rebuilding the client.
      #
      # The bridge tracks the value it last wrote
      # (`@k8s_rails_bridged_bearer_value`). If the app replaces
      # `api_key['BearerToken']` after client creation (explicit credential
      # rotation), the current value matches neither the bridge's last write
      # nor the value the bridge is about to write, so the bridge stops
      # syncing and the app's value stays authoritative — a user-set
      # `BearerToken` is never bridged or overwritten, before or after client
      # creation.
      def bridge_bearer_token(config)
        return if config.api_key["authorization"].nil?
        return if config.api_key.key?("BearerToken")
        return if config.instance_variable_get(:@k8s_rails_bridged_bearer)

        initial = config.api_key_with_prefix("authorization")
        config.api_key["BearerToken"] = initial
        config.instance_variable_set(:@k8s_rails_bridged_bearer, true)
        config.instance_variable_set(:@k8s_rails_bridged_bearer_value, initial)
        config.singleton_class.prepend(BridgedBearerSync)
      end

      # Prepend target of the K1 bridge (see bridge_bearer_token). kruby calls
      # `auth_settings` for every request; syncing here (not once at build
      # time) is what keeps a rotated in-cluster token fresh.
      #
      # Thread-safety: the token for THIS request is taken from the freshly
      # computed `authorization` value and written into THIS call's returned
      # settings hash directly — it is never read back from the shared
      # `api_key` (where a concurrent request's write could land in between),
      # so concurrent requests in a threaded Rails process cannot send a
      # stale copy. The shared key is still updated as the backing copy for
      # direct readers.
      module BridgedBearerSync
        def auth_settings
          settings = super
          sync_bridged_bearer(settings)
          settings
        end

        private

        def sync_bridged_bearer(settings)
          return unless instance_variable_get(:@k8s_rails_bridged_bearer)

          fresh = api_key_with_prefix("authorization")
          return if fresh.nil?
          return if app_overrode_bridged_token?(fresh)

          settings["BearerToken"][:value] = fresh
          api_key["BearerToken"] = fresh
          instance_variable_set(:@k8s_rails_bridged_bearer_value, fresh)
        end

        # The app replaced the bridged value (explicit credential rotation):
        # it matches neither the bridge's last write nor the value written
        # now. Stops the sync so the app's credential stays authoritative.
        def app_overrode_bridged_token?(fresh)
          current = api_key["BearerToken"]
          return false if current == instance_variable_get(:@k8s_rails_bridged_bearer_value) || current == fresh

          instance_variable_set(:@k8s_rails_bridged_bearer, false)
          true
        end
      end
    end

    # Wraps an ApiClient (or an injected test double) so that
    #   - every response is deep-stringified (K2), and
    #   - kruby errors are converted to K8sRails exceptions (K3).
    #
    # This is the ONLY place kruby response shapes / errors are touched, so a
    # kruby upgrade is a one-file change (§7). It speaks kruby's `call_api`
    # protocol directly, so it reaches core v1, named built-in groups, and
    # CRDs uniformly.
    class StringKeyedAdapter
      def initialize(transport)
        @transport = transport
      end

      # --- namespaced ------------------------------------------------------

      def list(group, version, namespace, plural)
        request(:GET, build_path(:namespaced, group, version, namespace, plural))
      end

      def get(group, version, namespace, plural, name)
        request(:GET, build_path(:namespaced, group, version, namespace, plural, name))
      end

      def create(group, version, namespace, plural, body)
        request(:POST, build_path(:namespaced, group, version, namespace, plural), body: body)
      end

      def patch(group, version, namespace, plural, name, body)
        request(
          :PATCH,
          build_path(:namespaced, group, version, namespace, plural, name),
          body: body,
          content_type: "application/json-patch+json"
        )
      end

      def delete(group, version, namespace, plural, name)
        request(:DELETE, build_path(:namespaced, group, version, namespace, plural, name))
      end

      # --- cluster-scoped --------------------------------------------------

      def list_cluster(group, version, plural)
        request(:GET, build_path(:cluster, group, version, nil, plural))
      end

      def get_cluster(group, version, plural, name)
        request(:GET, build_path(:cluster, group, version, nil, plural, name))
      end

      def create_cluster(group, version, plural, body)
        request(:POST, build_path(:cluster, group, version, nil, plural), body: body)
      end

      def patch_cluster(group, version, plural, name, body)
        request(
          :PATCH,
          build_path(:cluster, group, version, nil, plural, name),
          body: body,
          content_type: "application/json-patch+json"
        )
      end

      def delete_cluster(group, version, plural, name)
        request(:DELETE, build_path(:cluster, group, version, nil, plural, name))
      end

      private

      # Map the declaration coordinates to the API path (mirrors kubectl's
      # discovery-based routing):
      #   - core (group == ""):   /api/v1[/namespaces/{ns}]/{plural}[/{name}]
      #   - named (group != ""):  /apis/{group}/{version}[/namespaces/{ns}]/{plural}[/{name}]
      # `scope` :namespaced takes a namespace; :cluster passes nil (no
      # namespace in the path). `name` (when present) is CGI-escaped.
      def build_path(scope, group, version, namespace, plural, name = nil)
        prefix = group.to_s.empty? ? "/api/#{version}" : "/apis/#{group}/#{version}"
        middle = scope == :cluster ? "" : "/namespaces/#{CGI.escape(namespace.to_s)}"
        path = "#{prefix}#{middle}/#{CGI.escape(plural.to_s)}"
        name.nil? ? path : "#{path}/#{CGI.escape(name.to_s)}"
      end

      # Issue one request through kruby's call_api and normalize the result.
      # `return_type "Object"` makes kruby hand back the parsed JSON (symbol
      # keys); the Normalizer deep-stringifies it (K2). kruby errors are
      # converted to the K8sRails hierarchy (K3).
      def request(method, path, body: nil, content_type: "application/json")
        data, _status_code, _headers = @transport.call_api(method, path, call_opts(body, content_type))
        Normalizer.stringify(data)
      rescue Kubernetes::ApiError => e
        raise Client.convert_api_error(e)
      rescue Kubernetes::ConfigError, Typhoeus::Errors::TyphoeusError => e
        raise Unavailable, "K8s に接続できません: #{e.message}"
      end

      # The kruby call_api options hash (mirrors how kruby's generated API
      # methods assemble their request opts).
      def call_opts(body, content_type)
        {
          operation: :k8s_rails_request,
          header_params: { "Content-Type" => content_type },
          query_params: {},
          body: body,
          auth_names: ["BearerToken"],
          return_type: "Object"
        }
      end
    end

    # One-shot /version probe backed by VersionApi#get_code (the kruby 1.36.x
    # equivalent of a lightweight connectivity check).
    class VersionApiProbe
      def initialize(config)
        @api = Kubernetes::VersionApi.new(Kubernetes::ApiClient.new(config))
      end

      def probe
        @api.get_code
        true
      rescue Kubernetes::ApiError => e
        raise Client.convert_api_error(e)
      rescue Kubernetes::ConfigError, Typhoeus::Errors::TyphoeusError => e
        raise Unavailable, "K8s に接続できません: #{e.message}"
      end
    end
  end
end
