# frozen_string_literal: true

require "spec_helper"
# Client (and kruby) load lazily; pull it in for these tests.
require "k8s_rails/client"

RSpec.describe K8sRails::Client do
  before { K8sRails.reset! }

  # --- K1: Bearer token bridge --------------------------------------------

  describe "K1 bridge (api_key['authorization'] -> api_key['BearerToken'])" do
    it "duplicates the token when BearerToken is absent" do
      kconfig = Kubernetes::Configuration.new
      kconfig.api_key["authorization"] = "Bearer my-token"
      K8sRails.config.connection = kconfig

      K8sRails.client # triggers build_custom_objects_api

      expect(kconfig.api_key["BearerToken"]).to eq("Bearer my-token")
    end

    it "does not overwrite an existing BearerToken" do
      kconfig = Kubernetes::Configuration.new
      kconfig.api_key["authorization"] = "Bearer from-auth"
      kconfig.api_key["BearerToken"] = "Bearer existing"
      K8sRails.config.connection = kconfig

      K8sRails.client

      expect(kconfig.api_key["BearerToken"]).to eq("Bearer existing")
    end

    it "does nothing when there is no authorization key" do
      kconfig = Kubernetes::Configuration.new
      K8sRails.config.connection = kconfig

      K8sRails.client

      expect(kconfig.api_key.key?("BearerToken")).to be(false)
    end
  end

  # --- Lazy connect ---------------------------------------------------------

  describe "lazy connection" do
    it "builds without network I/O (in-memory CustomObjectsApi)" do
      kconfig = Kubernetes::Configuration.new
      kconfig.api_key["authorization"] = "Bearer tok"
      K8sRails.config.connection = kconfig

      expect { K8sRails.client }.not_to raise_error
    end

    it "caches the transport across builds" do
      kconfig = Kubernetes::Configuration.new
      K8sRails.config.connection = kconfig
      first = K8sRails.client
      second = K8sRails.client
      expect(first).to equal(second)
    end
  end

  # --- K2: response normalization ------------------------------------------

  describe "response normalization (K2)" do
    let(:fake) { FakeTransport.new }

    before { K8sRails.config.api_client = fake }

    it "deep-stringifies list responses" do
      out = K8sRails.client.list("g", "v", "n", "workflows")
      expect(out).to eq("items" => [{ "name" => "a" }], "kind" => "List")
    end

    it "deep-stringifies get responses" do
      out = K8sRails.client.get("g", "v", "n", "workflows", "wf-1")
      expect(out).to eq("metadata" => { "name" => "wf-1" })
    end

    it "deep-stringifies create responses" do
      out = K8sRails.client.create("g", "v", "n", "workflows", { metadata: { generateName: "x-" } })
      expect(out).to eq("metadata" => { "name" => "created", "generateName" => "x-" })
    end

    it "deep-stringifies patch responses" do
      out = K8sRails.client.patch("g", "v", "n", "workflows", "wf-1", [{ op: "add", path: "/a", value: 1 }])
      expect(out).to eq("metadata" => { "name" => "wf-1" }, "patched" => true)
    end

    # Cluster-scoped endpoints (#17): same normalization contract, kruby
    # *_cluster_custom_object signatures (no namespace argument).
    it "deep-stringifies list_cluster responses" do
      out = K8sRails.client.list_cluster("g", "v", "clusterissuers")
      expect(out).to eq("items" => [{ "name" => "a" }], "kind" => "List")
    end

    it "deep-stringifies get_cluster responses" do
      out = K8sRails.client.get_cluster("g", "v", "clusterissuers", "ci-1")
      expect(out).to eq("metadata" => { "name" => "ci-1" })
    end

    it "deep-stringifies create_cluster responses" do
      out = K8sRails.client.create_cluster("g", "v", "clusterissuers", { metadata: { generateName: "x-" } })
      expect(out).to eq("metadata" => { "name" => "created", "generateName" => "x-" })
    end

    it "deep-stringifies patch_cluster responses" do
      out = K8sRails.client.patch_cluster("g", "v", "clusterissuers", "ci-1", [{ op: "add", path: "/a", value: 1 }])
      expect(out).to eq("metadata" => { "name" => "ci-1" }, "patched" => true)
    end
  end

  # --- K3: exception conversion --------------------------------------------

  describe "exception conversion (K3)" do
    def with_raising_transport(err)
      K8sRails.config.api_client = RaisingTransport.new(err)
    end

    it "converts kruby ApiError 404 to K8sRails::NotFound" do
      with_raising_transport(Kubernetes::ApiError.new(code: 404, response_body: '{"msg":"not found"}'))
      expect { K8sRails.client.get("g", "v", "n", "workflows", "missing") }
        .to raise_error(K8sRails::NotFound)
    end

    it "converts kruby ApiError code 0 to K8sRails::Unavailable" do
      with_raising_transport(Kubernetes::ApiError.new(code: 0, message: "Could not resolve host"))
      expect { K8sRails.client.list("g", "v", "n", "p") }
        .to raise_error(K8sRails::Unavailable, /Could not resolve host/)
    end

    it "converts kruby ApiError 403 to K8sRails::ApiError keeping code and body" do
      with_raising_transport(Kubernetes::ApiError.new(code: 403, response_body: '{"msg":"forbidden"}'))
      expect { K8sRails.client.get("g", "v", "n", "workflows", "x") }
        .to raise_error(K8sRails::ApiError) do |e|
          expect(e.code).to eq(403)
          expect(e.response).to eq('{"msg":"forbidden"}')
        end
    end

    it "propagates programming errors (NoMethodError) unconverted" do
      K8sRails.config.api_client = Object.new # responds to nothing
      expect { K8sRails.client.list("g", "v", "n", "p") }
        .to raise_error(NoMethodError)
    end

    it "converts the same table for cluster-scoped operations (#17)" do
      with_raising_transport(Kubernetes::ApiError.new(code: 404, response_body: nil))
      expect { K8sRails.client.get_cluster("g", "v", "p", "missing") }
        .to raise_error(K8sRails::NotFound)
    end
  end

  # --- Test injection -------------------------------------------------------

  describe "config.api_client injection" do
    it "skips connection resolution and uses the injected transport" do
      fake = FakeTransport.new
      K8sRails.config.api_client = fake
      K8sRails.client.list("g", "v", "n", "workflows")
      expect(fake.calls).to eq([:list])
    end
  end

  # --- connected? -----------------------------------------------------------

  describe ".connected?" do
    it "raises Unavailable when the API is unreachable (connection refused)" do
      kconfig = Kubernetes::Configuration.new
      kconfig.host = "127.0.0.1:1"
      kconfig.scheme = "http"
      kconfig.ssl_ca_cert = nil
      K8sRails.config.connection = kconfig

      expect { K8sRails.connected? }.to raise_error(K8sRails::Unavailable)
    end

    it "applies the K1 bridge to the probe config (Authorization header is sent)" do
      kconfig = Kubernetes::Configuration.new
      kconfig.api_key["authorization"] = "Bearer probe-token"
      kconfig.host = "127.0.0.1:1"
      kconfig.scheme = "http"
      kconfig.ssl_ca_cert = nil
      K8sRails.config.connection = kconfig

      expect { K8sRails.connected? }.to raise_error(K8sRails::Unavailable)
      expect(kconfig.api_key["BearerToken"]).to eq("Bearer probe-token")
    end

    # #18: under transport injection the injected transport IS the connection
    # surface, so connected? returns true without probing a real endpoint.
    it "returns true without network I/O when api_client is injected (#18)" do
      K8sRails.config.api_client = FakeTransport.new

      expect(K8sRails.connected?).to be(true)
    end

    it "still probes the real endpoint when no transport is injected (#18)" do
      kconfig = Kubernetes::Configuration.new
      kconfig.host = "127.0.0.1:1"
      kconfig.scheme = "http"
      kconfig.ssl_ca_cert = nil
      K8sRails.config.connection = kconfig

      expect { K8sRails.connected? }.to raise_error(K8sRails::Unavailable)
    end
  end
end

# A fake transport implementing the four CustomObjects operations with
# SYMBOL keys, to prove the adapter normalizes to string keys.
class FakeTransport
  attr_reader :calls

  def initialize
    @calls = []
  end

  def list_namespaced_custom_object(_g, _v, _ns, _p)
    @calls << :list
    { items: [{ name: "a" }], kind: "List" }
  end

  def get_namespaced_custom_object(_g, _v, _ns, _p, name)
    @calls << :get
    { metadata: { name: name } }
  end

  def create_namespaced_custom_object(_g, _v, _ns, _p, body)
    @calls << :create
    { metadata: (body["metadata"] || body[:metadata] || {}).merge(name: "created") }
  end

  def patch_namespaced_custom_object(_g, _v, _ns, _p, name, _body)
    @calls << :patch
    { metadata: { name: name }, patched: true }
  end

  # Cluster-scoped variants (kruby *_cluster_custom_object: no namespace arg).
  def list_cluster_custom_object(_g, _v, _p)
    @calls << :list_cluster
    { items: [{ name: "a" }], kind: "List" }
  end

  def get_cluster_custom_object(_g, _v, _p, name)
    @calls << :get_cluster
    { metadata: { name: name } }
  end

  def create_cluster_custom_object(_g, _v, _p, body)
    @calls << :create_cluster
    { metadata: (body["metadata"] || body[:metadata] || {}).merge(name: "created") }
  end

  def patch_cluster_custom_object(_g, _v, _p, name, _body)
    @calls << :patch_cluster
    { metadata: { name: name }, patched: true }
  end
end

# A transport whose every operation raises a fixed kruby error, to exercise
# the K3 conversion table.
class RaisingTransport
  def initialize(error)
    @error = error
  end

  def list_namespaced_custom_object(*)
    raise @error
  end

  def get_namespaced_custom_object(*)
    raise @error
  end

  def create_namespaced_custom_object(*)
    raise @error
  end

  def patch_namespaced_custom_object(*)
    raise @error
  end

  def list_cluster_custom_object(*)
    raise @error
  end

  def get_cluster_custom_object(*)
    raise @error
  end

  def create_cluster_custom_object(*)
    raise @error
  end

  def patch_cluster_custom_object(*)
    raise @error
  end
end
