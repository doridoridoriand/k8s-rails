# frozen_string_literal: true

# KubeRails — Kubernetes API / CRD convention layer for Rails applications.
#
# Design: docs/design.md (KBR-DESIGN-001)
#
# Load-time contract (§3 / §7): requiring this entry point has NO side effects
# and does NOT load kruby. The kruby-dependent Client (and therefore kruby
# itself) is loaded lazily on the first `KubeRails::Client.build` /
# `KubeRails.connected?` call. This lets the gem be `require`d even when no
# cluster is reachable and keeps kruby's load cost out of app boot.
module KubeRails
  # Lazy load (§7): referencing KubeRails::Client (e.g. Client.build) is the
  # moment kruby is required — never at gem require time. Direct constant
  # access works, while a plain `require "kuberails"` stays kruby-free.
  autoload :Client, File.expand_path("kuberails/client", __dir__)

  class << self
    # Settings, set once via `configure` (§5.1).
    def config
      @config ||= Configuration.new
    end

    # Configure the gem. Runs once — a second call warns and is ignored
    # (design §5.1). Yields the Configuration object.
    def configure
      if @configured
        warn "[KubeRails] KubeRails.configure called more than once; ignoring the second call."
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
    #   Workflow = KubeRails.crd(group: "argoproj.io", version: "v1alpha1",
    #                            plural: "workflows", kind: "Workflow")
    # Re-declaring the same kind raises KubeRails::RedeclarationError.
    def crd(group:, version:, plural:, kind:, namespace: nil, readonly: true)
      CRD.declare(group:, version:, plural:, kind:, namespace:, readonly:)
    end
  end

  # Whether the kruby-dependent client file has actually been required yet
  # (an autoloaded-but-unreferenced constant still counts as "not loaded"
  # for `defined?`/`const_defined?`, so $LOADED_FEATURES is authoritative).
  def self.client_loaded?
    $LOADED_FEATURES.any? { |f| f.end_with?("kuberails/client.rb") }
  end
end

# Pure-Ruby components with no kruby dependency — safe to load eagerly.
require_relative "kuberails/version"
require_relative "kuberails/errors"
require_relative "kuberails/configuration"
require_relative "kuberails/normalizer"
require_relative "kuberails/crd"
