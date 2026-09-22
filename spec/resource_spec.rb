# frozen_string_literal: true

require "spec_helper"
# Resource itself never loads kruby, but the shared transport (K8sRails.client)
# does — load it explicitly so specs are deterministic regardless of file order.
require "k8s_rails/client"

RSpec.describe K8sRails::Resource do
  before do
    K8sRails.reset!
    @fake = RecordingTransport.new
    K8sRails.config.api_client = @fake
    @wf = K8sRails.crd(
      group: "argoproj.io",
      version: "v1alpha1",
      plural: "workflows",
      kind: "Workflow",
      namespace: "team-a"
    )
  end

  describe ".list" do
    it "returns the items array, string-keyed, using the declared namespace" do
      out = @wf.list

      expect(@fake.calls).to eq([[:GET, "/apis/argoproj.io/v1alpha1/namespaces/team-a/workflows", nil]])
      expect(out).to eq([
                          { "name" => "wf-1", "labels" => { "team" => "a" }, "spec" => { "steps" => 1 },
                            "status" => {} }
                        ])
    end

    it "accepts a namespace: override" do
      @wf.list(namespace: "team-b")
      expect(@fake.calls).to eq([[:GET, "/apis/argoproj.io/v1alpha1/namespaces/team-b/workflows", nil]])
    end

    it "falls back to K8sRails.config.namespace when the declaration has none" do
      K8sRails.config.namespace = "config-ns"
      bare = K8sRails.crd(group: "g", version: "v1", plural: "p", kind: "Bare")

      bare.list
      expect(@fake.calls).to eq([[:GET, "/apis/g/v1/namespaces/config-ns/p", nil]])
    end

    it "returns [] when the API response has no items" do
      @fake.list_items = nil
      expect(@wf.list).to eq([])
    end
  end

  describe ".find" do
    it "returns the object, string-keyed" do
      out = @wf.find("wf-1")
      expect(@fake.calls).to eq([[:GET, "/apis/argoproj.io/v1alpha1/namespaces/team-a/workflows/wf-1", nil]])
      expect(out).to eq("metadata" => { "name" => "wf-1" }, "spec" => { "a" => 1 })
    end

    it "raises K8sRails::NotFound when the API returns 404" do
      @fake.raise_on_get = Kubernetes::ApiError.new(code: 404, response_body: '{"msg":"not found"}')
      expect { @wf.find("missing") }.to raise_error(K8sRails::NotFound)
    end
  end

  describe ".find_or_nil" do
    it "returns nil on NotFound instead of raising" do
      @fake.raise_on_get = Kubernetes::ApiError.new(code: 404, response_body: nil)
      expect(@wf.find_or_nil("missing")).to be_nil
    end

    it "still raises for other API errors (403)" do
      @fake.raise_on_get = Kubernetes::ApiError.new(code: 403, response_body: nil)
      expect { @wf.find_or_nil("x") }.to raise_error(K8sRails::ApiError)
    end
  end

  describe ".create (K4 readonly gate)" do
    it "raises ReadOnlyError on a readonly: true declaration (the default)" do
      expect { @wf.create({ metadata: { name: "wf" } }) }.to raise_error(K8sRails::ReadOnlyError, /readonly/)
      expect(@fake.calls).to be_empty
    end

    it "calls the transport on a readonly: false declaration" do
      w = K8sRails.crd(group: "g", version: "v1", plural: "p", kind: "W", readonly: false)
      out = w.create({ metadata: { name: "w-1" } })

      expect(@fake.calls).to eq([[:POST, "/apis/g/v1/namespaces/default/p", { metadata: { name: "w-1" } }]])
      expect(out).to eq("metadata" => { "name" => "created" })
    end
  end

  describe ".patch (K4 readonly gate)" do
    it "raises ReadOnlyError on a readonly: true declaration (the default)" do
      ops = [{ op: "replace", path: "/spec/a", value: 2 }]
      expect { @wf.patch("wf-1", ops) }.to raise_error(K8sRails::ReadOnlyError, /readonly/)
      expect(@fake.calls).to be_empty
    end

    it "calls the transport on a readonly: false declaration" do
      w = K8sRails.crd(group: "g", version: "v1", plural: "p", kind: "W", readonly: false)
      ops = [{ op: "replace", path: "/spec/a", value: 2 }]
      out = w.patch("w-1", ops)

      expect(@fake.calls).to eq([[:PATCH, "/apis/g/v1/namespaces/default/p/w-1", ops]])
      expect(@fake.last_opts[:header_params]["Content-Type"]).to eq("application/json-patch+json")
      expect(out).to eq("metadata" => { "name" => "w-1" }, "patched" => true)
    end
  end

  describe ".delete (K4 readonly gate)" do
    it "raises ReadOnlyError on a readonly: true declaration (the default)" do
      expect { @wf.delete("wf-1") }.to raise_error(K8sRails::ReadOnlyError, /readonly/)
      expect(@fake.calls).to be_empty
    end

    it "calls the transport on a readonly: false declaration and returns the status" do
      w = K8sRails.crd(group: "g", version: "v1", plural: "p", kind: "W2", readonly: false)
      out = w.delete("w-1")

      expect(@fake.calls).to eq([[:DELETE, "/apis/g/v1/namespaces/default/p/w-1", nil]])
      expect(out).to eq("kind" => "Status", "status" => "Success", "details" => { "name" => "w-1" })
    end

    it "raises K8sRails::NotFound when the object is already gone" do
      w = K8sRails.crd(group: "g", version: "v1", plural: "p", kind: "W3", readonly: false)
      @fake.raise_on_delete = Kubernetes::ApiError.new(code: 404, response_body: nil)

      expect { w.delete("missing") }.to raise_error(K8sRails::NotFound)
    end
  end

  # --- Core v1 built-in resources (group: "") --------------------------------

  describe "core v1 built-in resources (group: \"\")" do
    before do
      @pod = K8sRails.crd(group: "", version: "v1", plural: "pods", kind: "Pod",
                          namespace: "default", readonly: false)
    end

    it "lists pods via the core /api/v1/... path" do
      @pod.list
      expect(@fake.calls).to eq([[:GET, "/api/v1/namespaces/default/pods", nil]])
    end

    it "finds a pod via the core path" do
      @pod.find("pod-1")
      expect(@fake.calls).to eq([[:GET, "/api/v1/namespaces/default/pods/pod-1", nil]])
    end

    it "creates a pod via the core path" do
      @pod.create({ metadata: { name: "pod-1" } })
      expect(@fake.calls).to eq([[:POST, "/api/v1/namespaces/default/pods", { metadata: { name: "pod-1" } }]])
    end

    it "deletes a pod via the core path" do
      @pod.delete("pod-1")
      expect(@fake.calls).to eq([[:DELETE, "/api/v1/namespaces/default/pods/pod-1", nil]])
    end

    it "lists cluster-scoped core resources (nodes) via /api/v1/nodes" do
      nodes = K8sRails.crd(group: "", version: "v1", plural: "nodes", kind: "Node", scope: :cluster)
      nodes.list_cluster
      expect(@fake.calls).to eq([[:GET, "/api/v1/nodes", nil]])
    end
  end

  # --- Named built-in groups (apps/v1, etc.) ---------------------------------

  describe "named built-in groups (apps/v1)" do
    it "routes deployments via /apis/apps/v1/..." do
      deployment = K8sRails.crd(group: "apps", version: "v1", plural: "deployments", kind: "Deployment")
      deployment.list(namespace: "team-a")
      expect(@fake.calls).to eq([[:GET, "/apis/apps/v1/namespaces/team-a/deployments", nil]])
    end
  end

  # --- Cluster-scoped CRDs (#17) ------------------------------------------

  describe "cluster-scoped (scope: :cluster)" do
    before do
      @ci = K8sRails.crd(
        group: "cert-manager.io",
        version: "v1",
        plural: "clusterissuers",
        kind: "ClusterIssuer",
        scope: :cluster
      )
    end

    it "list_cluster hits the cluster endpoint (no namespace in the path), string-keyed" do
      out = @ci.list_cluster
      expect(@fake.calls).to eq([[:GET, "/apis/cert-manager.io/v1/clusterissuers", nil]])
      expect(out).to eq([
                          { "name" => "wf-1", "labels" => { "team" => "a" }, "spec" => { "steps" => 1 },
                            "status" => {} }
                        ])
    end

    it "find_cluster returns the object, string-keyed" do
      out = @ci.find_cluster("letsencrypt")
      expect(@fake.calls).to eq([[:GET, "/apis/cert-manager.io/v1/clusterissuers/letsencrypt", nil]])
      expect(out).to eq("metadata" => { "name" => "letsencrypt" }, "spec" => { "a" => 1 })
    end

    it "find_or_nil_cluster returns nil on NotFound instead of raising" do
      @fake.raise_on_get = Kubernetes::ApiError.new(code: 404, response_body: nil)
      # find_cluster raises NotFound on the cluster path
      expect { @ci.find_cluster("missing") }.to raise_error(K8sRails::NotFound)
      # find_or_nil_cluster rescues NotFound
      expect(@ci.find_or_nil_cluster("missing")).to be_nil
    end

    it "create_cluster is gated by readonly (default true raises)" do
      expect { @ci.create_cluster({ metadata: { name: "ci" } }) }
        .to raise_error(K8sRails::ReadOnlyError, /readonly/)
      expect(@fake.calls).to be_empty
    end

    it "create_cluster calls the transport on a readonly: false declaration" do
      ci = K8sRails.crd(group: "g", version: "v1", plural: "clusterp", kind: "ClusterK",
                        scope: :cluster, readonly: false)
      out = ci.create_cluster({ metadata: { name: "c-1" } })
      expect(@fake.calls).to eq([[:POST, "/apis/g/v1/clusterp", { metadata: { name: "c-1" } }]])
      expect(out).to eq("metadata" => { "name" => "created" })
    end

    it "patch_cluster calls the transport on a readonly: false declaration" do
      ci = K8sRails.crd(group: "g", version: "v1", plural: "clusterp", kind: "ClusterK2",
                        scope: :cluster, readonly: false)
      ops = [{ op: "replace", path: "/spec/a", value: 2 }]
      out = ci.patch_cluster("c-1", ops)
      expect(@fake.calls).to eq([[:PATCH, "/apis/g/v1/clusterp/c-1", ops]])
      expect(out).to eq("metadata" => { "name" => "c-1" }, "patched" => true)
    end

    it "delete_cluster calls the transport on a readonly: false declaration" do
      ci = K8sRails.crd(group: "g", version: "v1", plural: "clusterp", kind: "ClusterK3",
                        scope: :cluster, readonly: false)
      out = ci.delete_cluster("c-1")
      expect(@fake.calls).to eq([[:DELETE, "/apis/g/v1/clusterp/c-1", nil]])
      expect(out).to eq("kind" => "Status", "status" => "Success", "details" => { "name" => "c-1" })
    end
  end

  describe "scope gate (bidirectional ArgumentError, #17)" do
    it "raises ArgumentError when *_cluster is called on a namespaced declaration" do
      expect { @wf.list_cluster }.to raise_error(ArgumentError, /scope: :cluster declaration/)
      expect { @wf.find_cluster("x") }.to raise_error(ArgumentError, /scope: :cluster declaration/)
      expect { @wf.delete_cluster("x") }.to raise_error(ArgumentError, /scope: :cluster declaration/)
      expect(@fake.calls).to be_empty
    end

    it "raises ArgumentError when the plain methods are called on a cluster declaration" do
      ci = K8sRails.crd(group: "g", version: "v1", plural: "clusterp", kind: "ClusterGate", scope: :cluster)
      expect { ci.list }.to raise_error(ArgumentError, /scope: :cluster/)
      expect { ci.find("x") }.to raise_error(ArgumentError, /scope: :cluster/)
      expect { ci.create({ metadata: { name: "x" } }) }.to raise_error(ArgumentError, /scope: :cluster/)
      expect { ci.patch("x", []) }.to raise_error(ArgumentError, /scope: :cluster/)
      expect { ci.delete("x") }.to raise_error(ArgumentError, /scope: :cluster/)
      expect(@fake.calls).to be_empty
    end

    it "readonly gate still applies on the cluster path (create before scope is independent)" do
      ci = K8sRails.crd(group: "g", version: "v1", plural: "clusterp", kind: "ClusterRO", scope: :cluster)
      # default readonly: true → ReadOnlyError, and the transport is never hit
      expect { ci.create_cluster({ metadata: { name: "x" } }) }
        .to raise_error(K8sRails::ReadOnlyError)
      expect { ci.delete_cluster("x") }.to raise_error(K8sRails::ReadOnlyError)
      expect(@fake.calls).to be_empty
    end
  end
end
