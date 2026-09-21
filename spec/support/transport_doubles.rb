# frozen_string_literal: true

# A recording fake implementing the four transport methods with SYMBOL keys
# (the adapter must stringify). Mirrors the kruby CustomObjectsApi arg order.
class RecordingTransport
  attr_reader :calls
  attr_accessor :list_items, :raise_on_get

  def initialize
    @calls = []
    @list_items = [{ name: "wf-1", labels: { team: "a" }, spec: { steps: 1 }, status: {} }]
  end

  def list_namespaced_custom_object(g, v, ns, p)
    @calls << [:list, g, v, ns, p]
    { items: @list_items, kind: "List" }
  end

  def get_namespaced_custom_object(g, v, ns, p, name)
    @calls << [:get, g, v, ns, p, name]
    raise @raise_on_get if @raise_on_get

    { metadata: { name: name }, spec: { a: 1 } }
  end

  def create_namespaced_custom_object(g, v, ns, p, body)
    @calls << [:create, g, v, ns, p, body]
    { metadata: { name: "created" } }
  end

  def patch_namespaced_custom_object(g, v, ns, p, name, body)
    @calls << [:patch, g, v, ns, p, name, body]
    { metadata: { name: name }, patched: true }
  end

  # Cluster-scoped variants (kruby *_cluster_custom_object signature: no
  # namespace argument).
  def list_cluster_custom_object(g, v, p)
    @calls << [:list_cluster, g, v, p]
    { items: [{ name: "ci-1", labels: { managed: true } }], kind: "List" }
  end

  def get_cluster_custom_object(g, v, p, name)
    @calls << [:get_cluster, g, v, p, name]
    raise @raise_on_get if @raise_on_get

    { metadata: { name: name }, spec: { a: 1 } }
  end

  def create_cluster_custom_object(g, v, p, body)
    @calls << [:create_cluster, g, v, p, body]
    { metadata: { name: "created-cluster" } }
  end

  def patch_cluster_custom_object(g, v, p, name, body)
    @calls << [:patch_cluster, g, v, p, name, body]
    { metadata: { name: name }, patched: true }
  end
end
