# frozen_string_literal: true

require_relative "resource"

module KubeRails
  # CRD declaration registry + DSL (design §5.3 / K5).
  #
  #   Workflow = KubeRails.crd(
  #     group: "argoproj.io", version: "v1alpha1",
  #     plural: "workflows", kind: "Workflow",
  #     namespace: KubeRails.config.namespace, # optional
  #     readonly: false,                        # default true
  #   )
  #
  # `crd` returns a `Resource` subclass with the coordinates bound; the same
  # class is registered under its kind name so a second declaration of the
  # same kind raises KubeRails::RedeclarationError (config-mistake detection).
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
    # kind are explicit — never guessed).
    def self.declare(group:, version:, plural:, kind:, namespace: nil, readonly: true)
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
