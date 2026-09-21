# frozen_string_literal: true

module K8sRails
  # Base for generated CRD access classes (design §5.3).
  #
  # A `K8sRails.crd` declaration returns a `Class.new(Resource)` with the
  # declared coordinates bound as class methods. All operations go through
  # the shared transport (`K8sRails.client`), which handles kruby error
  # conversion (K3) and response stringification (K2) — this class never
  # touches kruby itself (§7).
  #
  #   Workflow = K8sRails.crd(group: "argoproj.io", version: "v1alpha1",
  #                           plural: "workflows", kind: "Workflow")
  class Resource
    # Bind declared coordinates to a fresh anonymous subclass. `namespace`
    # may be nil — resolved from `K8sRails.config.namespace` at call time.
    # `scope` is :namespaced (default) or :cluster (design §5.3); cluster
    # declarations must not set `namespace`.
    def self.declare(group:, version:, plural:, kind:, namespace: nil, readonly: true, scope: :namespaced)
      Class.new(self) do
        define_singleton_method(:group_name) { group }
        define_singleton_method(:version_name) { version }
        define_singleton_method(:plural_name) { plural }
        define_singleton_method(:kind_name) { kind }
        define_singleton_method(:declared_namespace) { namespace }
        define_singleton_method(:readonly?) { readonly }
        define_singleton_method(:cluster_scoped?) { scope == :cluster }
      end
    end

    class << self
      # All objects in the namespace (namespaced declarations only —
      # cluster-scoped declarations raise ArgumentError). Returns an array
      # of string-keyed Hashes (design §5.3: `[{"name" => "...", ...}]`).
      def list(namespace: resolved_namespace)
        assert_namespaced
        K8sRails.instrument(:list, instrument_meta(namespace)) do
          transport.list(group_name, version_name, namespace, plural_name)["items"] || []
        end
      end

      # One object by name. Raises K8sRails::NotFound when absent.
      def find(name, namespace: resolved_namespace)
        assert_namespaced
        K8sRails.instrument(:find, instrument_meta(namespace)) do
          transport.get(group_name, version_name, namespace, plural_name, name)
        end
      end

      # Like `find`, but returns nil instead of raising on NotFound.
      def find_or_nil(name, namespace: resolved_namespace)
        find(name, namespace: namespace)
      rescue NotFound
        nil
      end

      # Create from a CRD body hash. `readonly: true` declarations raise
      # K8sRails::ReadOnlyError (K4).
      def create(attributes, namespace: resolved_namespace)
        assert_namespaced
        assert_writable
        K8sRails.instrument(:create, instrument_meta(namespace)) do
          transport.create(group_name, version_name, namespace, plural_name, attributes)
        end
      end

      # JSON Patch a named object. Same readonly restriction as `create`.
      def patch(name, operations, namespace: resolved_namespace)
        assert_namespaced
        assert_writable
        K8sRails.instrument(:patch, instrument_meta(namespace)) do
          transport.patch(group_name, version_name, namespace, plural_name, name, operations)
        end
      end

      # Cluster-scoped variants (design §5.3). Available on EVERY declared
      # class; a `scope: :namespaced` declaration raises ArgumentError (its
      # CRD is namespaced, so cluster endpoints 404 anyway).
      # All objects cluster-wide. Returns an array of string-keyed Hashes.
      def list_cluster
        assert_cluster_scoped
        K8sRails.instrument(:list, instrument_meta(nil)) do
          transport.list_cluster(group_name, version_name, plural_name)["items"] || []
        end
      end

      # One cluster-scoped object by name. Raises K8sRails::NotFound when absent.
      def find_cluster(name)
        assert_cluster_scoped
        K8sRails.instrument(:find, instrument_meta(nil)) do
          transport.get_cluster(group_name, version_name, plural_name, name)
        end
      end

      # Like `find_cluster`, but returns nil instead of raising on NotFound.
      def find_or_nil_cluster(name)
        find_cluster(name)
      rescue NotFound
        nil
      end

      # Create a cluster-scoped object. Same readonly restriction as `create`.
      def create_cluster(attributes)
        assert_cluster_scoped
        assert_writable
        K8sRails.instrument(:create, instrument_meta(nil)) do
          transport.create_cluster(group_name, version_name, plural_name, attributes)
        end
      end

      # JSON Patch a cluster-scoped object. Same readonly restriction.
      def patch_cluster(name, operations)
        assert_cluster_scoped
        assert_writable
        K8sRails.instrument(:patch, instrument_meta(nil)) do
          transport.patch_cluster(group_name, version_name, plural_name, name, operations)
        end
      end

      private

      # Notification metadata for design §8 (`k8s-rails.request`).
      def instrument_meta(namespace)
        { group: group_name, version: version_name, plural: plural_name, namespace: }
      end

      # Declared namespace wins; otherwise the gem default (resolved at call
      # time so `K8sRails.reset!` + reconfigure works in tests).
      def resolved_namespace
        declared_namespace || K8sRails.config.namespace
      end

      # Endless method: keeps the class under the ClassLength budget while
      # delegating to the shared transport (design §5.2).
      def transport = K8sRails.client

      def assert_writable
        return unless readonly?

        raise ReadOnlyError, "#{kind_name} is declared readonly — create/patch are disabled (K4)"
      end

      def assert_cluster_scoped
        return if cluster_scoped?

        raise ArgumentError,
              "#{kind_name} is namespaced — *_cluster methods require a scope: :cluster declaration"
      end

      def assert_namespaced
        return unless cluster_scoped?

        raise ArgumentError,
              "#{kind_name} is declared scope: :cluster — use the *_cluster methods " \
              "(there is no namespace endpoint for a cluster-scoped CRD)"
      end
    end
  end
end
