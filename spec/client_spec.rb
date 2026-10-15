# frozen_string_literal: true

require "spec_helper"
# Client (and kruby) load lazily; pull it in for these tests.
require "k8s_rails/client"
require "tempfile"

RSpec.describe K8sRails::Client do
  before { K8sRails.reset! }

  # --- K1: Bearer token bridge --------------------------------------------

  describe "K1 bridge (api_key['authorization'] -> api_key['BearerToken'])" do
    it "duplicates the token when BearerToken is absent" do
      kconfig = Kubernetes::Configuration.new
      kconfig.api_key["authorization"] = "Bearer my-token"
      K8sRails.config.connection = kconfig

      K8sRails.client # triggers build_api_client

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

  # --- K1 bridge refresh (#29) ----------------------------------------------

  describe "K1 bridge refresh (rotated tokens reach the header, #29)" do
    it "re-syncs the bridged BearerToken on every auth_settings call (per request), same cached client" do
      kconfig = Kubernetes::Configuration.new
      kconfig.api_key["authorization"] = "Bearer old-token"
      K8sRails.config.connection = kconfig

      first = K8sRails.client
      expect(kconfig.api_key["BearerToken"]).to eq("Bearer old-token")

      # Simulate an upstream refresh (kruby's in-cluster hook rewrites this
      # key inside api_key_with_prefix("authorization")).
      kconfig.api_key["authorization"] = "Bearer new-token"

      # The SAME cached client — no rebuild. kruby calls auth_settings for
      # every request; that is where the bridge re-syncs (before the header
      # is assembled), so read auth_settings first.
      expect(K8sRails.client).to equal(first)
      expect(kconfig.auth_settings["BearerToken"][:value]).to eq("Bearer new-token")
      expect(kconfig.api_key["BearerToken"]).to eq("Bearer new-token")
    end

    it "never overwrites a user-set BearerToken, even after upstream rotation" do
      kconfig = Kubernetes::Configuration.new
      kconfig.api_key["authorization"] = "Bearer from-auth"
      kconfig.api_key["BearerToken"] = "Bearer user-set"
      K8sRails.config.connection = kconfig

      K8sRails.client
      kconfig.api_key["authorization"] = "Bearer rotated"

      expect(kconfig.api_key["BearerToken"]).to eq("Bearer user-set")
      expect(kconfig.auth_settings["BearerToken"][:value]).to eq("Bearer user-set")
    end

    # PR #36 review (Codex P2): a BearerToken replaced by the application
    # AFTER client creation (explicit credential rotation) must reach the
    # header — the per-request re-sync must not clobber it — and the bridge
    # must stop syncing so the app's value stays authoritative.
    it "honors a BearerToken replaced after client creation and stops syncing" do
      kconfig = Kubernetes::Configuration.new
      kconfig.api_key["authorization"] = "Bearer in-cluster"
      K8sRails.config.connection = kconfig

      K8sRails.client
      expect(kconfig.api_key["BearerToken"]).to eq("Bearer in-cluster")

      # App-side rotation after the client exists.
      kconfig.api_key["BearerToken"] = "Bearer app-rotated"

      expect(kconfig.auth_settings["BearerToken"][:value]).to eq("Bearer app-rotated")

      # Upstream in-cluster rotation must not clobber the app's value.
      kconfig.api_key["authorization"] = "Bearer in-cluster-v2"
      expect(kconfig.auth_settings["BearerToken"][:value]).to eq("Bearer app-rotated")
      expect(kconfig.api_key["BearerToken"]).to eq("Bearer app-rotated")
    end

    # PR #36 review (Copilot): the token for a request must be the value
    # computed on that call, even when a concurrent request's stale write to
    # the shared key lands between this call's reads (threaded Rails). This
    # simulates that interleaving deterministically: the shared key is
    # clobbered with the pre-rotation token the moment `super` reads it.
    # On the pre-fix code (sync writes, then `super` re-reads the shared key)
    # the returned settings carry the stale token and this test fails.
    it "serves the freshly computed token without re-reading the shared key" do
      kconfig = Kubernetes::Configuration.new
      kconfig.api_key["authorization"] = "Bearer t1"
      K8sRails.config.connection = kconfig

      K8sRails.client
      kconfig.api_key["authorization"] = "Bearer t2" # upstream rotation

      clobber = Module.new do
        define_method(:api_key_with_prefix) do |name, param_alias = nil|
          if name == "BearerToken" && @sim_clobbered != true
            @api_key["BearerToken"] = "Bearer t1" # concurrent stale write
            @sim_clobbered = true
          end
          super(name, param_alias)
        end
      end
      kconfig.singleton_class.prepend(clobber)

      expect(kconfig.auth_settings["BearerToken"][:value]).to eq("Bearer t2")
    end

    # End-to-end on the REAL transport path (kruby ApiClient + Typhoeus):
    # an in-cluster token file rotation, with the refresh deadline expired,
    # must reach the Authorization header on the NEXT request — same cached
    # client, no rebuild. A local loopback HTTP server captures the header.
    it "sends the rotated in-cluster token after the refresh deadline (local HTTP server)" do
      token_file = Tempfile.new(["k8s-rails-spec-token", ".txt"])
      ca_file = Tempfile.new(["k8s-rails-spec-ca", ".txt"])
      token_file.write("review-old-token")
      token_file.flush
      server = LocalHttpServer.new(requests: 3).start
      loader = Kubernetes::InClusterConfig.new
      loader.instance_variable_set(:@env, {
                                     "KUBERNETES_SERVICE_HOST" => "127.0.0.1",
                                     "KUBERNETES_SERVICE_PORT" => server.port.to_s
                                   })
      loader.instance_variable_set(:@token_file, token_file.path)
      loader.instance_variable_set(:@ca_cert, ca_file.path)
      config = Kubernetes::Configuration.new
      loader.configure(config)
      # configure() forces https + the CA file; the auth path under test is
      # identical over plain http, so point the same config at the server.
      config.scheme = "http"
      config.ssl_ca_cert = nil
      K8sRails.config.connection = config
      pod = K8sRails.crd(group: "", version: "v1", plural: "pods", kind: "Pod")

      begin
        pod.find("p-1")
        expect(server.authorization_headers.last).to eq("Bearer review-old-token")

        # Rotate the token file and expire the refresh deadline: kruby's
        # hook must reload the file on the next api_key_with_prefix("authorization").
        token_file.rewind
        token_file.truncate(0)
        token_file.write("review-new-token")
        token_file.flush
        loader.token_expires_at = Time.now - 1

        pod.find("p-1")
        expect(server.authorization_headers.last).to eq("Bearer review-new-token")

        # connected? (VersionApi probe) shares the config → the same fresh
        # token (Resource operations and connectivity check agree, #29).
        expect(K8sRails.connected?).to be(true)
        expect(server.authorization_headers.last).to eq("Bearer review-new-token")
      ensure
        server.stop
        # Keep the token file alive for the rest of the suite: InClusterConfig
        # installs a process-wide refresh hook on Kubernetes::Configuration
        # (kruby design) that would re-read this file if it expired mid-suite.
        # Pushing the deadline far out makes the installed hook inert.
        loader.token_expires_at = Time.now + 3600
      end
    end
  end

  # --- Lazy connect ---------------------------------------------------------

  describe "lazy connection" do
    it "builds without network I/O (in-memory ApiClient)" do
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

  # #31: connected? must inspect the SAME connection the Resource operations
  # use. The resolved config is memoized for the cached transport's lifetime —
  # re-resolving would let the probe validate connection B while ops still
  # send to connection A. reset! is the explicit reload path.
  describe "connected? shares the cached connection with Resource ops (#31)" do
    def local_config(server)
      Kubernetes::Configuration.new.tap do |c|
        c.host = "http://127.0.0.1:#{server.port}"
      end
    end

    it "probes the cached config when the config resolution changes" do
      server_a = LocalHttpServer.new(requests: 2).start
      server_b = LocalHttpServer.new(requests: 2).start
      config_a = local_config(server_a)
      config_b = local_config(server_b)
      allow(Kubernetes::Configuration).to receive(:default_config).and_return(config_a, config_b)
      begin
        K8sRails.client.list("g", "v", "n", "p")
        K8sRails.connected?
        expect(server_a.authorization_headers.size).to eq(2)
        expect(server_b.authorization_headers.size).to eq(0)
      ensure
        server_a.stop
        server_b.stop
      end
    end

    it "applies the new config after reset! (explicit reload path)" do
      server_a = LocalHttpServer.new(requests: 2).start
      server_b = LocalHttpServer.new(requests: 2).start
      config_a = local_config(server_a)
      config_b = local_config(server_b)
      allow(Kubernetes::Configuration).to receive(:default_config).and_return(config_a, config_b)
      begin
        K8sRails.client.list("g", "v", "n", "p")
        K8sRails.reset!
        K8sRails.client.list("g", "v", "n", "p")
        K8sRails.connected?
        expect(server_a.authorization_headers.size).to eq(1)
        expect(server_b.authorization_headers.size).to eq(2)
      ensure
        server_a.stop
        server_b.stop
      end
    end

    # Deterministic concurrent-first-use regression (#31 review): with the
    # fix, the FIRST resolution runs inside BUILD_LOCK, so a racing
    # `connected?` cannot enter the resolution while the op thread holds it —
    # the stub is entered exactly once and the probe reuses the SAME cached
    # config. Without the lock both threads enter `build_configuration` and
    # the second write wins (calls == 2 → failure), recreating the
    # probe/operation mismatch. No sleeps: the op thread is PARKED inside the
    # resolution until the test releases it, so the "blocked probe" state is
    # a lock guarantee, not a timing window.
    it "resolves the connection config exactly once when a build and connected? race" do
      server_a = LocalHttpServer.new(requests: 2).start
      server_b = LocalHttpServer.new(requests: 2).start
      config_a = local_config(server_a)
      config_b = local_config(server_b)
      calls = 0
      entered = Queue.new
      release = Queue.new
      allow(Kubernetes::Configuration).to receive(:default_config) do
        calls += 1
        entered << calls
        release.pop
        calls == 1 ? config_a : config_b
      end

      begin
        op_thread = Thread.new { K8sRails.client.list("g", "v", "n", "p") }
        entered.pop # the op thread is now parked inside the resolution

        probe_thread = Thread.new { K8sRails.connected? }
        # The probe cannot finish while the op holds BUILD_LOCK (it is either
        # waiting on the lock or, without the fix, parked in the stub).
        expect(probe_thread.join(0.2)).to be_nil
        expect(calls).to eq(1)

        release << nil # unpark the op thread: it takes config_a and caches it
        op_thread.join(2)
        probe_thread.join(2)

        expect(server_a.authorization_headers.size).to eq(2)
        expect(server_b.authorization_headers.size).to eq(0)
        expect(calls).to eq(1)
      ensure
        2.times { release << nil } # unstick any thread parked in the stub
        op_thread&.join(1)
        probe_thread&.join(1)
        server_a.stop
        server_b.stop
        K8sRails.reset!
      end
    end
  end

  # --- HTTP timeout policy (#33) --------------------------------------------

  describe "http_timeout (finite default, explicit values win, #33)" do
    it "applies the 30s default when the resolved timeout is kruby's unset 0" do
      kconfig = Kubernetes::Configuration.new
      K8sRails.config.connection = kconfig

      K8sRails.client

      expect(kconfig.timeout).to eq(30)
    end

    it "never overrides an explicitly set connection.timeout" do
      kconfig = Kubernetes::Configuration.new
      kconfig.timeout = 7
      K8sRails.config.connection = kconfig

      K8sRails.client

      expect(kconfig.timeout).to eq(7)
    end

    it "preserves an explicitly set fractional connection.timeout (no to_i coercion)" do
      kconfig = Kubernetes::Configuration.new
      kconfig.timeout = 0.5
      K8sRails.config.connection = kconfig

      K8sRails.client

      expect(kconfig.timeout).to eq(0.5)
    end

    it "applies a custom http_timeout when the connection timeout is unset" do
      kconfig = Kubernetes::Configuration.new
      K8sRails.config.connection = kconfig
      K8sRails.config.http_timeout = 5

      K8sRails.client

      expect(kconfig.timeout).to eq(5)
    end

    it "http_timeout = 0 opts out and leaves kruby's unlimited default (0)" do
      kconfig = Kubernetes::Configuration.new
      K8sRails.config.connection = kconfig
      K8sRails.config.http_timeout = 0

      K8sRails.client

      expect(kconfig.timeout).to eq(0)
    end

    it "rejects a non-Integer http_timeout (Float silently truncates to 0 = unlimited)" do
      kconfig = Kubernetes::Configuration.new
      K8sRails.config.connection = kconfig
      K8sRails.config.http_timeout = 0.5

      expect { K8sRails.client }.to raise_error(ArgumentError, /http_timeout/)
    end

    it "rejects a negative http_timeout with ArgumentError" do
      kconfig = Kubernetes::Configuration.new
      K8sRails.config.connection = kconfig
      K8sRails.config.http_timeout = -1

      expect { K8sRails.client }.to raise_error(ArgumentError, /http_timeout/)
    end

    it "is idempotent: a re-resolution sees the applied value as explicit and skips" do
      kconfig = Kubernetes::Configuration.new
      K8sRails.config.connection = kconfig
      K8sRails.client
      expect(kconfig.timeout).to eq(30)

      # reset! rebuilds the shared configuration, so re-attach the SAME
      # connection — otherwise the second build would resolve the ambient
      # default_config and the assertion below would test an abandoned
      # object. With a DIFFERENT knob value on the second resolution, the
      # already-applied 30 must read as explicit and stay untouched.
      K8sRails.reset!
      K8sRails.config.connection = kconfig
      K8sRails.config.http_timeout = 5
      K8sRails.client

      expect(kconfig.timeout).to eq(30)
    end

    # The `connected?` probe resolves the SAME configuration — the policy
    # must hold there too (#33: Resource operations and the connectivity
    # check agree). A loopback server answers the real /version probe.
    it "applies the policy on the connected? probe path (loopback)" do
      server = LocalHttpServer.new(requests: 1).start
      kconfig = Kubernetes::Configuration.new
      kconfig.scheme = "http"
      kconfig.host = "127.0.0.1:#{server.port}"
      kconfig.api_key["BearerToken"] = "timeout-probe"
      K8sRails.config.connection = kconfig

      expect(K8sRails.connected?).to be(true)
      expect(kconfig.timeout).to eq(30)
    ensure
      server.stop
    end

    # End-to-end on the REAL transport path (kruby ApiClient + Typhoeus): a
    # finite timeout turns a slow response into K8sRails::Unavailable on
    # BOTH Resource operations and the connectivity probe (#33 完了条件).
    # The explicit connection.timeout = 1 also proves the policy leaves it
    # untouched while the conversion still happens.
    it "converts a slow response into Unavailable on the op and probe paths" do
      slow = SlowResponseServer.new(delay: 3).start
      kconfig = Kubernetes::Configuration.new
      kconfig.scheme = "http"
      kconfig.host = "127.0.0.1:#{slow.port}"
      kconfig.api_key["BearerToken"] = "timeout-probe"
      kconfig.timeout = 1 # finite, well below the server delay
      K8sRails.config.connection = kconfig
      pod = K8sRails.crd(group: "", version: "v1", plural: "pods", kind: "Pod")

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { pod.find("p-1") }.to raise_error(K8sRails::Unavailable)
      # Lower bound only (CI is slow): proves the 1s client-side timeout was
      # actually enforced, not an instant failure — the 3s server delay
      # means an unbounded-wait regression would raise nothing instead.
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be >= 0.9

      expect { K8sRails.connected? }.to raise_error(K8sRails::Unavailable)
    ensure
      slow&.stop
    end
  end

  # --- Path building (core v1 vs named group, namespaced vs cluster) --------

  describe "API path building" do
    let(:fake) { FakeTransport.new }
    before { K8sRails.config.api_client = fake }

    it "builds a named namespaced path /apis/{group}/{version}/namespaces/{ns}/{plural}" do
      K8sRails.client.list("apps", "v1", "team-a", "deployments")
      expect(fake.paths).to eq([["/apis/apps/v1/namespaces/team-a/deployments"]])
    end

    it "builds a core v1 namespaced path /api/v1/namespaces/{ns}/{plural} for an empty group" do
      K8sRails.client.get("", "v1", "default", "pods", "pod-1")
      expect(fake.paths).to eq([["/api/v1/namespaces/default/pods/pod-1"]])
    end

    it "builds a named cluster path without a namespace segment" do
      K8sRails.client.list_cluster("cert-manager.io", "v1", "clusterissuers")
      expect(fake.paths).to eq([["/apis/cert-manager.io/v1/clusterissuers"]])
    end

    it "builds a core v1 cluster path /api/v1/{plural} for nodes" do
      K8sRails.client.list_cluster("", "v1", "nodes")
      expect(fake.paths).to eq([["/api/v1/nodes"]])
    end

    it "CGI-escapes the name segment" do
      K8sRails.client.get("", "v1", "default", "pods", "a/b")
      expect(fake.paths).to eq([["/api/v1/namespaces/default/pods/a%2Fb"]])
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

    it "deep-stringifies delete responses (API status object)" do
      out = K8sRails.client.delete("g", "v", "n", "workflows", "wf-1")
      expect(out).to eq("kind" => "Status", "status" => "Success")
    end

    # Cluster-scoped endpoints (#17): same normalization contract, no namespace
    # segment in the path.
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

    it "deep-stringifies delete_cluster responses" do
      out = K8sRails.client.delete_cluster("g", "v", "clusterissuers", "ci-1")
      expect(out).to eq("kind" => "Status", "status" => "Success")
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

    it "converts kruby ApiError code 0 to K8sRails::Unavailable (with the original as cause)" do
      with_raising_transport(Kubernetes::ApiError.new(code: 0, message: "Could not resolve host"))
      expect { K8sRails.client.list("g", "v", "n", "p") }
        .to raise_error(K8sRails::Unavailable, /Could not resolve host/) do |e|
          expect(e.cause).to be_a(Kubernetes::ApiError)
        end
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

    it "converts delete 404 to NotFound" do
      with_raising_transport(Kubernetes::ApiError.new(code: 404, response_body: nil))
      expect { K8sRails.client.delete("g", "v", "n", "p", "missing") }
        .to raise_error(K8sRails::NotFound)
    end
  end

  # --- Test injection -------------------------------------------------------

  # #30: the kubeconfig load (KUBECONFIG -> ~/.kube/config -> in-cluster)
  # happens in build_configuration, BEFORE any request — a broken kubeconfig
  # must surface as the public Unavailable (same contract as the
  # transport-time conversion), with the original error as #cause. The rescue
  # is narrow: programming errors still propagate (see the NoMethodError spec
  # in "exception conversion" above).
  describe "config load-time conversion (#30)" do
    def with_bad_kubeconfig
      kubeconfig = Tempfile.new(["k8s-rails-spec-kubeconfig", ".yaml"])
      kubeconfig.write(<<~YAML)
        apiVersion: v1
        kind: Config
        current-context: missing
        contexts: []
        clusters: []
        users: []
      YAML
      kubeconfig.close
      kubeconfig
    end

    def with_kubeconfig(path)
      old_kubeconfig = ENV["KUBECONFIG"]
      ENV["KUBECONFIG"] = path
      yield
    ensure
      ENV["KUBECONFIG"] = old_kubeconfig
    end

    it "converts a kubeconfig load failure to Unavailable on Resource.list (raw ConfigError must not leak)" do
      kubeconfig = with_bad_kubeconfig
      with_kubeconfig(kubeconfig.path) do
        wf = K8sRails.crd(group: "", version: "v1", plural: "pods", kind: "Pod")
        error = nil
        expect { wf.list }.to raise_error(K8sRails::Unavailable) { |e| error = e }
        expect(error.cause).to be_a(Kubernetes::ConfigError)
      end
    ensure
      kubeconfig.unlink
    end

    it "converts the same load failure on connected?" do
      kubeconfig = with_bad_kubeconfig
      with_kubeconfig(kubeconfig.path) do
        error = nil
        expect { K8sRails.connected? }.to raise_error(K8sRails::Unavailable) { |e| error = e }
        expect(error.cause).to be_a(Kubernetes::ConfigError)
      end
    ensure
      kubeconfig.unlink
    end
  end

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

# A fake transport implementing kruby's `Kubernetes::ApiClient#call_api`
# protocol with SYMBOL-keyed responses, to prove the adapter normalizes to
# string keys. Records the op symbol (@calls) and the built path (@paths).
class FakeTransport
  attr_reader :calls, :paths

  def initialize
    @calls = []
    @paths = []
  end

  # kruby call_api returns [data, status_code, headers].
  def call_api(method, path, opts = {})
    @paths << [path]
    op = op_name(method, path)
    @calls << op
    [response_for(op, path, opts), 200, {}]
  end

  private

  def op_name(method, path)
    case method
    when :GET then collection_path?(path) ? :list : :get
    when :POST then :create
    when :PATCH then :patch
    when :DELETE then :delete
    else method
    end
  end

  def response_for(op, path, opts)
    case op
    when :list then { items: [{ name: "a" }], kind: "List" }
    when :get then { metadata: { name: name_of(path) } }
    when :create then create_response(opts)
    when :patch then { metadata: { name: name_of(path) }, patched: true }
    when :delete then { kind: "Status", status: "Success" }
    else {}
    end
  end

  def create_response(opts)
    body = opts[:body] || {}
    meta = body[:metadata] || body["metadata"] || {}
    { metadata: meta.merge(name: "created") }
  end

  def name_of(path)
    path.split("/").last
  end

  # A collection path ends at the plural; an object path has one more segment.
  # core (/api/{v}...) has 2 leading segments, named (/apis/{g}/{v}...) has 3.
  # The cluster collection check must come first: /api/v1/namespaces
  # (the Namespace resource itself) has the plural where a scope marker would.
  def collection_path?(path)
    parts = path.split("/").reject(&:empty?)
    size = parts.size
    base = parts.first == "api" ? 2 : 3
    return true if size == base + 1 # cluster collection (incl. /api/v1/namespaces)

    parts[base] == "namespaces" && size == base + 3
  end
end

# A transport whose every operation raises a fixed kruby error, to exercise
# the K3 conversion table.
class RaisingTransport
  def initialize(error)
    @error = error
  end

  def call_api(*)
    raise @error
  end
end
