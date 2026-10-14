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
        @build ||= if (injected = K8sRails.config.api_client)
                     StringKeyedAdapter.new(injected)
                   else
                     StringKeyedAdapter.new(build_api_client)
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

        config = build_configuration
        # The probe also authenticates — apply the K1 bridge or the Authorization
        # header would be empty on clusters where /version requires auth.
        bridge_bearer_token(config)
        VersionApiProbe.new(config).probe
      end

      # Reset cached connection + transport (test support, §5.1).
      def reset!
        @build = nil
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
      def build_api_client
        config = build_configuration
        bridge_bearer_token(config)
        Kubernetes::ApiClient.new(config)
      end

      def build_configuration
        K8sRails.config.connection || Kubernetes::Configuration.default_config
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
