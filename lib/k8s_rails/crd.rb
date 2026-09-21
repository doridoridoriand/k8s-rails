# frozen_string_literal: true

require_relative "resource"

module K8sRails
  # CRD declaration registry + DSL (design §5.3 / K5).
  #
  #   Workflow = K8sRails.crd(
  #     group: "argoproj.io", version: "v1alpha1",
  #     plural: "workflows", kind: "Workflow",
  #     namespace: K8sRails.config.namespace, # optional
  #     readonly: false,                        # default true
  #   )
  #
  # `crd` returns a `Resource` subclass with the coordinates bound; the same
  # class is registered under its kind name so a second declaration of the
  # same kind raises K8sRails::RedeclarationError (config-mistake detection).
  # The registry is in-memory: no kruby, no network at declaration time.
  class CRD
    # Registered kinds, e.g. { "Workflow" => Workflow }.
    def self.registered
      @registered ||= {}
    end

    def self.clear!
      @registered = {}
    end

    # Declare a CRD and return its Resource class (K5: group/version/plural/
    # kind are explicit — never guessed). `readonly` must be an explicit
    # boolean: mutations are enabled ONLY by `readonly: false` (design §5.3 /
    # K4), so nil/other values fail fast instead of silently allowing writes.
    def self.declare(group:, version:, plural:, kind:, namespace: nil, readonly: true)
      unless [true, false].include?(readonly)
        raise ArgumentError,
              "readonly must be true or false (got #{readonly.inspect}) — mutations require an explicit readonly: false"
      end

      if registered.key?(kind)
        raise RedeclarationError, "CRD kind #{kind} is already declared — re-declaration is a configuration mistake"
      end

      resource = Resource.declare(
        group: group,
        version: version,
        plural: plural,
        kind: kind,
        namespace: namespace,
        readonly: readonly
      )
      registered[kind] = resource
      resource
    end
  end
end
