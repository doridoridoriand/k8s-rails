# frozen_string_literal: true

# K8sRails — Kubernetes API / CRD convention layer for Rails applications.
#
# Design: docs/design.md (KBR-DESIGN-001)
#
# Load-time contract (§3 / §7): requiring this entry point has NO side effects
# and does NOT load kruby. The kruby-dependent Client (and therefore kruby
# itself) is loaded lazily on the first `K8sRails::Client.build` /
# `K8sRails.connected?` call. This lets the gem be `require`d even when no
# cluster is reachable and keeps kruby's load cost out of app boot.
module K8sRails
  # Lazy load (§7): referencing K8sRails::Client (e.g. Client.build) is the
  # moment kruby is required — never at gem require time. Direct constant
  # access works, while a plain `require "k8s-rails"` stays kruby-free.
  autoload :Client, File.expand_path("k8s_rails/client", __dir__)

  class << self
    # Settings, set once via `configure` (§5.1).
    def config
      @config ||= Configuration.new
    end

    # Configure the gem. Runs once — a second call warns and is ignored
    # (design §5.1). Yields the Configuration object.
    def configure
      if @configured
        warn "[K8sRails] K8sRails.configure called more than once; ignoring the second call."
        return config
      end

      @configured = true
      yield config
      config
    end

    # Reset configuration, the cached transport, and declared CRDs.
    # Test support (§5.1).
    def reset!
      @config = nil
      @configured = false
      CRD.clear!
      Client.reset! if client_loaded?
    end

    # The shared transport (design §5.2). Triggers the lazy load of the
    # kruby-dependent Client on first call.
    def client
      Client.build
    end

    # Lightweight connectivity check (§5.2). Raises Unavailable/ApiError.
    def connected?
      Client.connected?
    end

    # Declare a CRD and return its Resource class (design §5.3, K5).
    #   Workflow = K8sRails.crd(group: "argoproj.io", version: "v1alpha1",
    #                            plural: "workflows", kind: "Workflow")
    # Re-declaring the same kind raises K8sRails::RedeclarationError.
    def crd(group:, version:, plural:, kind:, namespace: nil, readonly: true)
      CRD.declare(group:, version:, plural:, kind:, namespace:, readonly:)
    end

    # Design §8: run an API call inside a `k8s-rails.request` notification.
    #
    #   K8sRails.instrument(:list, group: "g", version: "v1", plural: "p", namespace: "ns") do
    #     # ... actual transport call ...
    #   end
    #
    # The notification payload is
    #   { operation:, group:, version:, plural:, namespace:, duration_ms:,
    #     status: "ok" | "unavailable" | "api_error" }.
    # The block's return value always flows through unchanged. No-op when
    # `config.instrumentation` is false or ActiveSupport is not loaded.
    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength -- fixed §8 wrapper
    def instrument(operation, metadata)
      return yield unless instrumentation_enabled?

      payload = { operation: operation }.merge(metadata)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        result = yield
        payload[:status] = "ok"
      rescue K8sRails::Unavailable
        payload[:status] = "unavailable"
        raise
      rescue K8sRails::ApiError, K8sRails::NotFound
        payload[:status] = "api_error"
        raise
      ensure
        # Fallback for exceptions outside the K8sRails hierarchy (e.g. a
        # programming error like NoMethodError from a malformed stub): keep
        # the documented status enum (ok/unavailable/api_error) intact while
        # re-raising the original exception.
        payload[:status] ||= "api_error"
        payload[:duration_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round(2)
        ActiveSupport::Notifications.instrument("k8s-rails.request", payload)
      end
      result
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

    # True only when the user opted in AND ActiveSupport is actually loaded
    # (spec helper may stub this to exercise the no-op path deterministically).
    def instrumentation_enabled?
      config.instrumentation && defined?(ActiveSupport::Notifications)
    end
  end

  # Whether the kruby-dependent client file has actually been required yet
  # (an autoloaded-but-unreferenced constant still counts as "not loaded"
  # for `defined?`/`const_defined?`, so $LOADED_FEATURES is authoritative).
  def self.client_loaded?
    $LOADED_FEATURES.any? { |f| f.end_with?("k8s_rails/client.rb") }
  end
end

# Pure-Ruby components with no kruby dependency — safe to load eagerly.
require_relative "k8s_rails/version"
require_relative "k8s_rails/errors"
require_relative "k8s_rails/configuration"
require_relative "k8s_rails/normalizer"
require_relative "k8s_rails/crd"
