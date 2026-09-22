# frozen_string_literal: true

# A recording fake implementing kruby's `Kubernetes::ApiClient#call_api`
# contract with SYMBOL-keyed responses (the adapter must stringify). Routes on
# (http_method, path) exactly like the real ApiClient: the path carries the
# full resource coordinates (core v1 / named group / namespaced / cluster).
class RecordingTransport
  attr_reader :calls, :last_opts
  attr_accessor :list_items, :raise_on_get, :raise_on_delete

  def initialize
    @calls = []
    @list_items = [{ name: "wf-1", labels: { team: "a" }, spec: { steps: 1 }, status: {} }]
  end

  # kruby call_api returns [data, status_code, headers].
  def call_api(method, path, opts = {})
    @calls << [method, path, opts[:body]]
    @last_opts = opts
    [response_for(method, path, opts), 200, {}]
  end

  private

  def response_for(method, path, opts)
    case method
    when :GET then get_response(path)
    when :POST then create_response(opts)
    when :PATCH then { metadata: { name: name_of(path) }, patched: true }
    when :DELETE then delete_response(path)
    end
  end

  def get_response(path)
    raise @raise_on_get if @raise_on_get && !collection_path?(path)

    return { items: @list_items, kind: "List" } if collection_path?(path)

    { metadata: { name: name_of(path) }, spec: { a: 1 } }
  end

  def create_response(opts)
    body = opts[:body] || {}
    meta = body[:metadata] || body["metadata"] || {}
    { metadata: meta.merge(name: "created") }
  end

  def delete_response(path)
    raise @raise_on_delete if @raise_on_delete

    { kind: "Status", status: "Success", details: { name: name_of(path) } }
  end

  def name_of(path)
    path.split("/").reject(&:empty?).last
  end

  # A collection path ends at the plural; an object path has one extra name
  # segment. Core paths start at /api/{version} (2 leading segments), named at
  # /apis/{group}/{version} (3). The cluster collection check (size == base+1)
  # MUST come first: the Namespace resource's cluster collection is
  # /api/v1/namespaces, where the plural sits exactly where a scope marker
  # would — position-based checks alone misclassify it.
  def collection_path?(path)
    parts = path.split("/").reject(&:empty?)
    size = parts.size
    base = parts.first == "api" ? 2 : 3
    return true if size == base + 1 # cluster collection (incl. /api/v1/namespaces)

    parts[base] == "namespaces" && size == base + 3
  end
end
