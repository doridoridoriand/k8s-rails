# frozen_string_literal: true

require "spec_helper"
# Client (and kruby) load lazily; pull it in for these tests.
require "kuberails/client"

RSpec.describe KubeRails::Client do
  before { KubeRails.reset! }

  # --- K1: Bearer token bridge --------------------------------------------

  describe "K1 bridge (api_key['authorization'] -> api_key['BearerToken'])" do
    it "duplicates the token when BearerToken is absent" do
      kconfig = Kubernetes::Configuration.new
      kconfig.api_key["authorization"] = "Bearer my-token"
      KubeRails.config.connection = kconfig

      KubeRails.client # triggers build_custom_objects_api

      expect(kconfig.api_key["BearerToken"]).to eq("Bearer my-token")
    end

    it "does not overwrite an existing BearerToken" do
      kconfig = Kubernetes::Configuration.new
      kconfig.api_key["authorization"] = "Bearer from-auth"
      kconfig.api_key["BearerToken"] = "Bearer existing"
      KubeRails.config.connection = kconfig

      KubeRails.client

      expect(kconfig.api_key["BearerToken"]).to eq("Bearer existing")
    end

    it "does nothing when there is no authorization key" do
      kconfig = Kubernetes::Configuration.new
      KubeRails.config.connection = kconfig

      KubeRails.client

      expect(kconfig.api_key.key?("BearerToken")).to be(false)
    end
  end

  # --- Lazy connect ---------------------------------------------------------

  describe "lazy connection" do
    it "builds without network I/O (in-memory CustomObjectsApi)" do
      kconfig = Kubernetes::Configuration.new
      kconfig.api_key["authorization"] = "Bearer tok"
      KubeRails.config.connection = kconfig

      expect { KubeRails.client }.not_to raise_error
    end

    it "caches the transport across builds" do
      kconfig = Kubernetes::Configuration.new
      KubeRails.config.connection = kconfig
      first = KubeRails.client
      second = KubeRails.client
      expect(first).to equal(second)
    end
  end

  # --- K2: response normalization ------------------------------------------

  describe "response normalization (K2)" do
    let(:fake) { FakeTransport.new }

    before { KubeRails.config.api_client = fake }

    it "deep-stringifies list responses" do
      out = KubeRails.client.list("g", "v", "n", "workflows")
      expect(out).to eq("items" => [{ "name" => "a" }], "kind" => "List")
    end

    it "deep-stringifies get responses" do
      out = KubeRails.client.get("g", "v", "n", "workflows", "wf-1")
      expect(out).to eq("metadata" => { "name" => "wf-1" })
    end

    it "deep-stringifies create responses" do
      out = KubeRails.client.create("g", "v", "n", "workflows", { metadata: { generateName: "x-" } })
      expect(out).to eq("metadata" => { "name" => "created", "generateName" => "x-" })
    end

    it "deep-stringifies patch responses" do
      out = KubeRails.client.patch("g", "v", "n", "workflows", "wf-1", [{ op: "add", path: "/a", value: 1 }])
      expect(out).to eq("metadata" => { "name" => "wf-1" }, "patched" => true)
    end
  end

  # --- K3: exception conversion --------------------------------------------

  describe "exception conversion (K3)" do
    def with_raising_transport(err)
      KubeRails.config.api_client = RaisingTransport.new(err)
    end

    it "converts kruby ApiError 404 to KubeRails::NotFound" do
      with_raising_transport(Kubernetes::ApiError.new(code: 404, response_body: '{"msg":"not found"}'))
      expect { KubeRails.client.get("g", "v", "n", "workflows", "missing") }
        .to raise_error(KubeRails::NotFound)
    end

    it "converts kruby ApiError code 0 to KubeRails::Unavailable" do
      with_raising_transport(Kubernetes::ApiError.new(code: 0, message: "Could not resolve host"))
      expect { KubeRails.client.list("g", "v", "n", "p") }
        .to raise_error(KubeRails::Unavailable, /Could not resolve host/)
    end

    it "converts kruby ApiError 403 to KubeRails::ApiError keeping code and body" do
      with_raising_transport(Kubernetes::ApiError.new(code: 403, response_body: '{"msg":"forbidden"}'))
      expect { KubeRails.client.get("g", "v", "n", "workflows", "x") }
        .to raise_error(KubeRails::ApiError) do |e|
          expect(e.code).to eq(403)
          expect(e.response).to eq('{"msg":"forbidden"}')
        end
    end

    it "propagates programming errors (NoMethodError) unconverted" do
      KubeRails.config.api_client = Object.new # responds to nothing
      expect { KubeRails.client.list("g", "v", "n", "p") }
        .to raise_error(NoMethodError)
    end
  end

  # --- Test injection -------------------------------------------------------

  describe "config.api_client injection" do
    it "skips connection resolution and uses the injected transport" do
      fake = FakeTransport.new
      KubeRails.config.api_client = fake
      KubeRails.client.list("g", "v", "n", "workflows")
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
      KubeRails.config.connection = kconfig

      expect { KubeRails.connected? }.to raise_error(KubeRails::Unavailable)
    end

    it "applies the K1 bridge to the probe config (Authorization header is sent)" do
      kconfig = Kubernetes::Configuration.new
      kconfig.api_key["authorization"] = "Bearer probe-token"
      kconfig.host = "127.0.0.1:1"
      kconfig.scheme = "http"
      kconfig.ssl_ca_cert = nil
      KubeRails.config.connection = kconfig

      expect { KubeRails.connected? }.to raise_error(KubeRails::Unavailable)
      expect(kconfig.api_key["BearerToken"]).to eq("Bearer probe-token")
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
end
