# frozen_string_literal: true

require "spec_helper"
# Client (and kruby) load lazily; pull it in for these tests.
require "k8s_rails/client"
require "tempfile"
require "json"

# Boundary-condition regression layer (#34): the REAL kruby ApiClient
# (typhoeus/libcurl request pipeline) against loopback HTTP servers — no
# cluster, no external network. This pins what actually hits the wire (URL,
# HTTP method, Content-Type, Authorization header, request body) and how
# responses and errors come back (string-keyed deserialization, K3
# conversion), complementing the stub-transport unit layer (design §9). The
# stub layer alone could not detect the bugs behind #28-#32, which is why
# this layer exists.
# Canned K8s Status responses for the error-conversion specs (file-level so
# they are not redefined inside the describe block).
STATUS_404 = '{"kind":"Status","apiVersion":"v1","status":"Failure",' \
             '"message":"not found","code":404}'
STATUS_401 = '{"kind":"Status","apiVersion":"v1","status":"Failure",' \
             '"message":"unauthorized","code":401}'
STATUS_500 = '{"kind":"Status","apiVersion":"v1","status":"Failure",' \
             '"message":"internal","code":500}'
STATUS_403 = '{"kind":"Status","apiVersion":"v1","status":"Failure",' \
             '"message":"forbidden","code":403}'

RSpec.describe "real kruby transport boundary conditions (#34)" do
  before { K8sRails.reset! }

  # Inject the REAL kruby ApiClient as the transport: every operation then
  # runs through kruby's full request pipeline (auth_settings -> typhoeus ->
  # libcurl) to the loopback server, exactly as it would against a cluster.
  def start_real_transport(server, token: "Bearer real-transport-token")
    config = Kubernetes::Configuration.new
    config.scheme = "http"
    config.host = "127.0.0.1:#{server.port}"
    config.api_key["BearerToken"] = token
    # A finite client-side timeout keeps a transport-level wedge out of the
    # suite: a stuck request fails fast as Unavailable instead of hanging.
    config.timeout = 5
    K8sRails.config.api_client = Kubernetes::ApiClient.new(config)
  end

  describe "request surface through the real kruby ApiClient (#34)" do
    it "sends GET on the core-v1 namespaced collection path with the Authorization header" do
      server = RecordingHttpServer.new(requests: 1).start
      begin
        start_real_transport(server)
        pod = K8sRails.crd(group: "", version: "v1", plural: "pods", kind: "Pod")
        pod.list(namespace: "default")

        entry = server.last
        expect(entry.http_method).to eq("GET")
        expect(entry.path).to eq("/api/v1/namespaces/default/pods")
        expect(entry.content_type).to eq("application/json")
        expect(entry.authorization).to eq("Bearer real-transport-token")
      ensure
        server.stop
      end
    end

    it "sends GET on the named-group namespaced object path" do
      server = RecordingHttpServer.new(requests: 1).start
      begin
        start_real_transport(server)
        deployment = K8sRails.crd(group: "apps", version: "v1", plural: "deployments", kind: "Deployment")
        deployment.find("d-1", namespace: "default")

        entry = server.last
        expect(entry.http_method).to eq("GET")
        expect(entry.path).to eq("/apis/apps/v1/namespaces/default/deployments/d-1")
      ensure
        server.stop
      end
    end

    it "sends POST with the collection path, Content-Type application/json and the JSON body" do
      server = RecordingHttpServer.new(requests: 1).start
      begin
        start_real_transport(server)
        configmap = K8sRails.crd(group: "", version: "v1", plural: "configmaps", kind: "ConfigMap", readonly: false)
        body = { metadata: { name: "app-config" }, data: { "KEY" => "value" } }
        configmap.create(body, namespace: "default")

        entry = server.last
        expect(entry.http_method).to eq("POST")
        expect(entry.path).to eq("/api/v1/namespaces/default/configmaps")
        expect(entry.content_type).to eq("application/json")
        expect(JSON.parse(entry.body)).to eq(JSON.parse(body.to_json))
      ensure
        server.stop
      end
    end

    it "sends PATCH with Content-Type application/json-patch+json on the object path" do
      server = RecordingHttpServer.new(requests: 1).start
      begin
        start_real_transport(server)
        pod = K8sRails.crd(group: "", version: "v1", plural: "pods", kind: "Pod", readonly: false)
        ops = [{ op: "replace", path: "/metadata/labels", value: { "tier" => "web" } }]
        pod.patch("p-1", ops, namespace: "default")

        entry = server.last
        expect(entry.http_method).to eq("PATCH")
        expect(entry.path).to eq("/api/v1/namespaces/default/pods/p-1")
        expect(entry.content_type).to eq("application/json-patch+json")
        expect(JSON.parse(entry.body)).to eq([{ "op" => "replace", "path" => "/metadata/labels",
                                                "value" => { "tier" => "web" } }])
      ensure
        server.stop
      end
    end

    it "sends DELETE on the object path and returns the string-keyed Status object" do
      server = RecordingHttpServer.new(
        requests: 1,
        responses: [{ status: 200, body: '{"kind":"Status","apiVersion":"v1","status":"Success"}' }]
      ).start
      begin
        start_real_transport(server)
        pod = K8sRails.crd(group: "", version: "v1", plural: "pods", kind: "Pod", readonly: false)
        result = pod.delete("p-1", namespace: "default")

        entry = server.last
        expect(entry.http_method).to eq("DELETE")
        expect(entry.path).to eq("/api/v1/namespaces/default/pods/p-1")
        expect(result).to eq({ "kind" => "Status", "apiVersion" => "v1", "status" => "Success" })
      ensure
        server.stop
      end
    end

    it "delivers the CGI-escaped object name verbatim — libcurl does not rewrite the built path" do
      server = RecordingHttpServer.new(requests: 2).start
      begin
        start_real_transport(server)
        pod = K8sRails.crd(group: "", version: "v1", plural: "pods", kind: "Pod")
        pod.find("a b", namespace: "default")
        pod.find("x/y", namespace: "default")

        expect(server.entries.map(&:path)).to eq([
                                                   "/api/v1/namespaces/default/pods/a+b",
                                                   "/api/v1/namespaces/default/pods/x%2Fy"
                                                 ])
      ensure
        server.stop
      end
    end

    it "omits the namespace segment for cluster-scoped collections and objects" do
      server = RecordingHttpServer.new(requests: 2).start
      begin
        start_real_transport(server)
        namespaces = K8sRails.crd(group: "", version: "v1", plural: "namespaces", kind: "Namespace", scope: :cluster)
        namespaces.list_cluster
        nodes = K8sRails.crd(group: "", version: "v1", plural: "nodes", kind: "Node", scope: :cluster)
        nodes.find_cluster("n-1")

        expect(server.entries.map(&:path)).to eq([
                                                   "/api/v1/namespaces", # cluster collection: the plural itself is last
                                                   "/api/v1/nodes/n-1"
                                                 ])
        expect(server.entries.map(&:http_method)).to eq(%w[GET GET])
      ensure
        server.stop
      end
    end

    it "builds named-group cluster paths without a namespace segment" do
      server = RecordingHttpServer.new(requests: 1).start
      begin
        start_real_transport(server)
        crds = K8sRails.crd(group: "apiextensions.k8s.io", version: "v1", plural: "customresourcedefinitions",
                            kind: "CustomResourceDefinition", scope: :cluster)
        crds.find_cluster("widgets.example.com")

        expect(server.last.http_method).to eq("GET")
        expect(server.last.path).to eq("/apis/apiextensions.k8s.io/v1/customresourcedefinitions/widgets.example.com")
      ensure
        server.stop
      end
    end

    it "deserializes the response deep string-keyed (kruby symbol keys -> Normalizer)" do
      server = RecordingHttpServer.new(
        requests: 1,
        responses: [{ status: 200, body: '{"kind":"Pod","metadata":{"name":"p-1","labels":{"tier":"web"}}}' }]
      ).start
      begin
        start_real_transport(server)
        pod = K8sRails.crd(group: "", version: "v1", plural: "pods", kind: "Pod")
        result = pod.find("p-1", namespace: "default")

        expect(result["kind"]).to eq("Pod")
        expect(result["metadata"].key?("name")).to be(true)
        expect(result["metadata"]["labels"]["tier"]).to eq("web")
        expect(result.key?(:metadata)).to be(false)
      ensure
        server.stop
      end
    end

    it "converts a real 404 into K8sRails::NotFound" do
      server = RecordingHttpServer.new(
        requests: 1,
        responses: [{ status: 404, body: STATUS_404 }]
      ).start
      begin
        start_real_transport(server)
        pod = K8sRails.crd(group: "", version: "v1", plural: "pods", kind: "Pod")

        expect { pod.find("missing", namespace: "default") }.to raise_error(K8sRails::NotFound)
      ensure
        server.stop
      end
    end

    it "converts a real 401 and 500 into K8sRails::ApiError with the HTTP code kept" do
      pod = K8sRails.crd(group: "", version: "v1", plural: "pods", kind: "Pod")

      server = RecordingHttpServer.new(requests: 1, responses: [{ status: 401, body: STATUS_401 }]).start
      begin
        start_real_transport(server)
        expect { pod.find("p-1", namespace: "default") }
          .to raise_error(K8sRails::ApiError) { |e| expect(e.code).to eq(401) }
      ensure
        server.stop
      end

      K8sRails.reset!
      server = RecordingHttpServer.new(requests: 1, responses: [{ status: 500, body: STATUS_500 }]).start
      begin
        start_real_transport(server)
        expect { pod.find("p-1", namespace: "default") }
          .to raise_error(K8sRails::ApiError) { |e| expect(e.code).to eq(500) }
      ensure
        server.stop
      end
    end

    it "converts a real 403 into K8sRails::ApiError with the HTTP code kept (#34)" do
      server = RecordingHttpServer.new(requests: 1, responses: [{ status: 403, body: STATUS_403 }]).start
      begin
        start_real_transport(server)
        pod = K8sRails.crd(group: "", version: "v1", plural: "pods", kind: "Pod")

        expect { pod.find("p-1", namespace: "default") }
          .to raise_error(K8sRails::ApiError) { |e| expect(e.code).to eq(403) }
      ensure
        server.stop
      end
    end
  end

  # Transport failures that never produce an HTTP response: connection refused
  # and connection dropped mid-request (server accepts, then closes). kruby
  # surfaces both as Typhoeus errors, which the gem converts to
  # K8sRails::Unavailable. Timeouts are covered by the slow-response specs in
  # client_spec.rb (#33, real transport + real timeout) — not duplicated here.
  describe "transport failure boundaries (#34)" do
    it "converts connection-refused into Unavailable (nothing listens on the port)" do
      config = Kubernetes::Configuration.new
      config.scheme = "http"
      config.host = "127.0.0.1:1" # closed port — no server, no cluster
      config.timeout = 5
      K8sRails.config.api_client = Kubernetes::ApiClient.new(config)
      pod = K8sRails.crd(group: "", version: "v1", plural: "pods", kind: "Pod")

      expect { pod.list(namespace: "default") }.to raise_error(K8sRails::Unavailable)
    end

    it "converts a connection dropped mid-request into Unavailable (accept, then close)" do
      server = DroppingHttpServer.new.start
      begin
        config = Kubernetes::Configuration.new
        config.scheme = "http"
        config.host = "127.0.0.1:#{server.port}"
        config.timeout = 5
        K8sRails.config.api_client = Kubernetes::ApiClient.new(config)
        pod = K8sRails.crd(group: "", version: "v1", plural: "pods", kind: "Pod")

        expect { pod.list(namespace: "default") }.to raise_error(K8sRails::Unavailable)
      ensure
        server.stop
      end
    end
  end

  describe "config resolution from a kubeconfig file (KUBECONFIG, #34)" do
    def with_kubeconfig(path)
      old_kubeconfig = ENV["KUBECONFIG"]
      ENV["KUBECONFIG"] = path
      yield
    ensure
      ENV["KUBECONFIG"] = old_kubeconfig
    end

    it "resolves the server, context and token from the file and sends them on the wire" do
      server = RecordingHttpServer.new(requests: 1).start
      kubeconfig = Tempfile.new(["k8s-rails-spec-kubeconfig", ".yaml"])
      kubeconfig.write(<<~YAML)
        apiVersion: v1
        kind: Config
        clusters:
        - name: local
          cluster:
            server: http://127.0.0.1:#{server.port}
        contexts:
        - name: local
          context:
            cluster: local
            user: local
        current-context: local
        users:
        - name: local
          user:
            token: dummy-kubeconfig-token
      YAML
      kubeconfig.flush
      begin
        with_kubeconfig(kubeconfig.path) do
          # The build resolves the connection from KUBECONFIG (no I/O); the
          # REAL transport it builds is what sends the request.
          K8sRails.client
          pod = K8sRails.crd(group: "", version: "v1", plural: "pods", kind: "Pod")
          pod.find("p-1", namespace: "default")

          entry = server.last
          expect(entry.authorization).to eq("Bearer dummy-kubeconfig-token")
          expect(entry.path).to eq("/api/v1/namespaces/default/pods/p-1")
        end
      ensure
        server.stop
        kubeconfig.close!
      end
    end
  end
end

# A loopback server that ACCEPTS a connection and closes it without writing
# anything — the libcurl-level "connection reset / recv failure" boundary.
# Same parked-in-accept readiness gate as RecordingHttpServer.
class DroppingHttpServer
  attr_reader :port

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
  end

  def start
    @thread = Thread.new do
      loop do
        io = begin
          @server.accept
        rescue IOError
          break
        end
        begin
          io.close
        rescue IOError, Errno::EPIPE
          nil
        end
      end
    end
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    Thread.pass until @thread.status == "sleep" || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    self
  end

  def stop
    @server.close
    @thread&.join
  end
end
