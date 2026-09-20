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

    # Reset configuration, the cached transport, and (M2) declared CRDs.
    # Test support (§5.1).
    def reset!
      @config = nil
      @configured = false
      Client.reset! if loaded?(:client)
    end

    # The shared transport (design §5.2). Triggers the lazy load of the
    # kruby-dependent Client on first call.
    def client
      load_client.build
    end

    # Lightweight connectivity check (§5.2). Raises Unavailable/ApiError.
    def connected?
      load_client.connected?
    end
  end

  # --- Lazy loading (kruby stays out of boot time) -------------------------

  # Whether a sub-component has been required already.
  def self.loaded?(name)
    $LOADED_FEATURES.any? { |f| f.end_with?("kuberails/#{name}.rb") }
  end

  # The Client (and kruby) are loaded on first use, never at require time.
  def self.load_client
    require_relative "kuberails/client" unless loaded?(:client)
    const_get(:Client)
  end
end

# Pure-Ruby components with no kruby dependency — safe to load eagerly.
require_relative "kuberails/version"
require_relative "kuberails/errors"
require_relative "kuberails/configuration"
require_relative "kuberails/normalizer"
