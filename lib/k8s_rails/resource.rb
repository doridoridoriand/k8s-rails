# frozen_string_literal: true

module K8sRails
  # Base for generated CRD / built-in access classes (design §5.3).
  #
  # A `K8sRails.crd` declaration returns a `Class.new(Resource)` with the
  # declared coordinates bound as class methods. All operations go through the
  # shared transport (`K8sRails.client`), which handles kruby error conversion
  # (K3) and response stringification (K2) — this class never touches kruby (§7).
  class Resource
    # Bind declared coordinates to a fresh anonymous subclass. `namespace` may
    # be nil (resolved from `K8sRails.config.namespace` at call time); `scope`
    # is :namespaced (default) or :cluster (cluster declarations: no namespace).
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
      # All objects in the namespace; returns an array of string-keyed Hashes.
      def list(namespace: resolved_namespace)
        run_operation(:list, :namespaced, namespace: namespace) do
          transport.list(group_name, version_name, namespace, plural_name)["items"] || []
        end
      end

      # One object by name. Raises K8sRails::NotFound when absent.
      def find(name, namespace: resolved_namespace)
        run_operation(:find, :namespaced, namespace: namespace) do
          transport.get(group_name, version_name, namespace, plural_name, name)
        end
      end

      # Like `find`, but returns nil instead of raising on NotFound.
      def find_or_nil(name, namespace: resolved_namespace)
        find(name, namespace: namespace)
      rescue NotFound
        nil
      end

      # Create from a body hash. `readonly: true` declarations raise ReadOnlyError.
      def create(attributes, namespace: resolved_namespace)
        run_operation(:create, :namespaced, namespace: namespace, writable: true) do
          transport.create(group_name, version_name, namespace, plural_name, attributes)
        end
      end

      # JSON Patch a named object. Same readonly restriction as `create`.
      def patch(name, operations, namespace: resolved_namespace)
        run_operation(:patch, :namespaced, namespace: namespace, writable: true) do
          transport.patch(group_name, version_name, namespace, plural_name, name, operations)
        end
      end

      # Delete a named object; returns the API status object. Same readonly
      # restriction; raises NotFound when already gone.
      def delete(name, namespace: resolved_namespace)
        run_operation(:delete, :namespaced, namespace: namespace, writable: true) do
          transport.delete(group_name, version_name, namespace, plural_name, name)
        end
      end

      # Cluster-scoped variants (design §5.3); a namespaced declaration raises
      # ArgumentError (its endpoints 404 on the cluster path anyway).
      def list_cluster
        run_operation(:list, :cluster) do
          transport.list_cluster(group_name, version_name, plural_name)["items"] || []
        end
      end

      # One cluster-scoped object by name. Raises NotFound when absent.
      def find_cluster(name)
        run_operation(:find, :cluster) do
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
        run_operation(:create, :cluster, writable: true) do
          transport.create_cluster(group_name, version_name, plural_name, attributes)
        end
      end

      # JSON Patch a cluster-scoped object. Same readonly restriction.
      def patch_cluster(name, operations)
        run_operation(:patch, :cluster, writable: true) do
          transport.patch_cluster(group_name, version_name, plural_name, name, operations)
        end
      end

      # Delete a cluster-scoped object. Same readonly restriction as `delete`.
      def delete_cluster(name)
        run_operation(:delete, :cluster, writable: true) do
          transport.delete_cluster(group_name, version_name, plural_name, name)
        end
      end

      private

      # Scope gate + readonly gate (§5.3) + §8 instrumentation for every
      # operation. The block value (and any K8sRails exception) flows through
      # unchanged. Cluster-scoped operations carry no namespace.
      def run_operation(operation, scope, namespace: nil, writable: false, &block)
        scope == :cluster ? assert_cluster_scoped : assert_namespaced
        assert_writable if writable
        ns = scope == :cluster ? nil : namespace
        K8sRails.instrument(operation, instrument_meta(ns)) { block.call }
      end

      # Notification metadata for design §8 (`k8s-rails.request`).
      def instrument_meta(namespace) = { group: group_name, version: version_name, plural: plural_name, namespace: }

      # Declared namespace wins; otherwise the gem default (resolved at call
      # time so `K8sRails.reset!` + reconfigure works in tests).
      def resolved_namespace = declared_namespace || K8sRails.config.namespace

      # Endless method: delegates to the shared transport (design §5.2).
      def transport = K8sRails.client

      def assert_writable
        return unless readonly?

        raise ReadOnlyError, "#{kind_name} is declared readonly — create/patch/delete are disabled (K4)"
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
