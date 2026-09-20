# frozen_string_literal: true

module KubeRails
  # Base for generated CRD access classes (design §5.3).
  #
  # A `KubeRails.crd` declaration returns a `Class.new(Resource)` with the
  # declared coordinates bound as class methods. All operations go through
  # the shared transport (`KubeRails.client`), which handles kruby error
  # conversion (K3) and response stringification (K2) — this class never
  # touches kruby itself (§7).
  #
  #   Workflow = KubeRails.crd(group: "argoproj.io", version: "v1alpha1",
  #                            plural: "workflows", kind: "Workflow")
  #   Workflow.list
  #   Workflow.find("wf-1")
  class Resource
    # Bind declared coordinates to a fresh anonymous subclass. `namespace`
    # may be nil — resolved from `KubeRails.config.namespace` at call time.
    def self.declare(group:, version:, plural:, kind:, namespace: nil, readonly: true)
      Class.new(self) do
        define_singleton_method(:group_name) { group }
        define_singleton_method(:version_name) { version }
        define_singleton_method(:plural_name) { plural }
        define_singleton_method(:kind_name) { kind }
        define_singleton_method(:declared_namespace) { namespace }
        define_singleton_method(:readonly?) { readonly }
      end
    end

    class << self
      # All objects in the namespace. Returns an array of string-keyed Hashes
      # (design §5.3: `[{ "name" => "...", ... }]`).
      def list(namespace: resolved_namespace)
        transport.list(group_name, version_name, namespace, plural_name)["items"] || []
      end

      # One object by name. Raises KubeRails::NotFound when absent.
      def find(name, namespace: resolved_namespace)
        transport.get(group_name, version_name, namespace, plural_name, name)
      end

      # Like `find`, but returns nil instead of raising on NotFound.
      def find_or_nil(name, namespace: resolved_namespace)
        find(name, namespace: namespace)
      rescue NotFound
        nil
      end

      # Create from a CRD body hash. `readonly: true` declarations raise
      # KubeRails::ReadOnlyError (K4).
      def create(attributes, namespace: resolved_namespace)
        assert_writable
        transport.create(group_name, version_name, namespace, plural_name, attributes)
      end

      # JSON Patch a named object. Same readonly restriction as `create`.
      def patch(name, operations, namespace: resolved_namespace)
        assert_writable
        transport.patch(group_name, version_name, namespace, plural_name, name, operations)
      end

      private

      # Declared namespace wins; otherwise the gem default (resolved at call
      # time so `KubeRails.reset!` + reconfigure works in tests).
      def resolved_namespace
        declared_namespace || KubeRails.config.namespace
      end

      def transport
        KubeRails.client
      end

      def assert_writable
        return unless readonly?

        raise ReadOnlyError, "#{kind_name} is declared readonly — create/patch are disabled (K4)"
      end
    end
  end
end
