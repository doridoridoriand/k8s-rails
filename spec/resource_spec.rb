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

      expect(@fake.calls).to eq([[:list, "argoproj.io", "v1alpha1", "team-a", "workflows"]])
      expect(out).to eq([
                          { "name" => "wf-1", "labels" => { "team" => "a" }, "spec" => { "steps" => 1 },
                            "status" => {} }
                        ])
    end

    it "accepts a namespace: override" do
      @wf.list(namespace: "team-b")
      expect(@fake.calls).to eq([[:list, "argoproj.io", "v1alpha1", "team-b", "workflows"]])
    end

    it "falls back to K8sRails.config.namespace when the declaration has none" do
      K8sRails.config.namespace = "config-ns"
      bare = K8sRails.crd(group: "g", version: "v1", plural: "p", kind: "Bare")

      bare.list
      expect(@fake.calls).to eq([[:list, "g", "v1", "config-ns", "p"]])
    end

    it "returns [] when the API response has no items" do
      @fake.list_items = nil
      expect(@wf.list).to eq([])
    end
  end

  describe ".find" do
    it "returns the object, string-keyed" do
      out = @wf.find("wf-1")
      expect(@fake.calls).to eq([[:get, "argoproj.io", "v1alpha1", "team-a", "workflows", "wf-1"]])
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

      expect(@fake.calls).to eq([[:create, "g", "v1", "default", "p", { metadata: { name: "w-1" } }]])
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

      expect(@fake.calls).to eq([[:patch, "g", "v1", "default", "p", "w-1", ops]])
      expect(out).to eq("metadata" => { "name" => "w-1" }, "patched" => true)
    end
  end
end
