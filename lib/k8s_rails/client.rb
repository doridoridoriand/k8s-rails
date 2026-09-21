# frozen_string_literal: true

# kruby の require は本ファイルにのみ許される（design §7）。
# 他のファイルは kruby の定数・クラスを参照しない。
# Typhoeus は kruby が require するため転送層例外もここに閉じ込める。
require "kubernetes"

module K8sRails
  # Resolves a connection to the Kubernetes API and exposes the four
  # CustomObjects operations as a small internal transport (design §5.2 / §7).
  #
  #   api = K8sRails::Client.build
  #   api.list(group, version, namespace, plural)
  #   api.get(group, version, namespace, plural, name)
  #   api.create(group, version, namespace, plural, body)
  #   api.patch(group, version, namespace, plural, name, body)
  #
  # Connection is LAZY: `build` does no network I/O — it only resolves a
  # `Kubernetes::Configuration` and builds an in-memory `CustomObjectsApi`.
  # The first real call is where DNS/timeout/TLS can fail.
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
      #      token under 'authorization' but auth_settings reads 'BearerToken').
      #   3. Build `ApiClient` → `CustomObjectsApi` (in-memory, no I/O).
      #   4. Wrap in a StringKeyedAdapter that normalizes responses (K2) and
      #      converts kruby errors to K8sRails exceptions.
      def build
        @build ||=
          if (injected = K8sRails.config.api_client)
            StringKeyedAdapter.new(injected)
          else
            StringKeyedAdapter.new(build_custom_objects_api)
          end
      end

      # Lightweight connectivity probe (design §5.2). Performs one lightweight
      # `/version` call via VersionApi and returns true on success. Raises
      # K8sRails::Unavailable / ApiError on failure (the app may rescue).
      def connected?
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

      # Build a lazy in-memory CustomObjectsApi from the resolved configuration.
      def build_custom_objects_api
        config = build_configuration
        bridge_bearer_token(config)
        api_client = Kubernetes::ApiClient.new(config)
        Kubernetes::CustomObjectsApi.new(api_client)
      end

      def build_configuration
        K8sRails.config.connection || Kubernetes::Configuration.default_config
      end

      # K1 bridge (kruby 1.36.x quirk): InClusterConfig writes the Bearer token
      # to `api_key['authorization']` (and the KUBECONFIG path can too), but
      # `Configuration#auth_settings` reads `api_key['BearerToken']` for the
      # `Authorization` header. Without the bridge the header is empty → 401.
      # Duplicate only when the target key is not already set.
      def bridge_bearer_token(config)
        auth = config.api_key["authorization"]
        return if auth.nil? || config.api_key.key?("BearerToken")

        config.api_key["BearerToken"] = auth
      end
    end

    # Wraps a CustomObjectsApi (or an injected test double) so that
    #   - every response is deep-stringified (K2), and
    #   - kruby errors are converted to K8sRails exceptions (K3).
    #
    # The adapter is the ONLY place kruby response shapes / errors are touched,
    # so a kruby upgrade is a one-file change (§7).
    class StringKeyedAdapter
      def initialize(transport)
        @transport = transport
      end

      def list(group, version, namespace, plural)
        handle do
          Normalizer.stringify(
            @transport.list_namespaced_custom_object(group, version, namespace, plural)
          )
        end
      end

      def get(group, version, namespace, plural, name)
        handle do
          Normalizer.stringify(
            @transport.get_namespaced_custom_object(group, version, namespace, plural, name)
          )
        end
      end

      def create(group, version, namespace, plural, body)
        handle do
          Normalizer.stringify(
            @transport.create_namespaced_custom_object(group, version, namespace, plural, body)
          )
        end
      end

      def patch(group, version, namespace, plural, name, body)
        handle do
          Normalizer.stringify(
            @transport.patch_namespaced_custom_object(group, version, namespace, plural, name, body)
          )
        end
      end

      private

      def handle
        yield
      rescue Kubernetes::ApiError => e
        raise Client.convert_api_error(e)
      rescue Kubernetes::ConfigError, Typhoeus::Errors::TyphoeusError => e
        raise Unavailable, "K8s に接続できません: #{e.message}"
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
