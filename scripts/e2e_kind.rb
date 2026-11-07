# frozen_string_literal: true

# Isolated-cluster E2E for k8s-rails (#34).
#
# Exercises the gem against a REAL Kubernetes API server (a kind cluster):
#   - connection setup (`connected?`) and cluster-scoped reads
#     (Node list_cluster, Namespace find_cluster) and a named-group read
#     (Deployment list)
#   - namespaced CRUD on throwaway objects: a ConfigMap (immediate deletion ->
#     Status response) and a Pod (graceful deletion -> the object itself with
#     `metadata.deletionTimestamp`, per the delete response contract)
#   - cleanup assertions: both probe objects must be gone at exit
#
# SAFETY GUARD: the script refuses to run unless the current kubectl context
# is a kind cluster ("kind-*"), so a personal / production kubeconfig is never
# targeted. It uses whatever the KUBECONFIG env var (or ~/.kube/config)
# resolves to. Create a cluster and run:
#
#   kind create cluster --name k8s-rails-e2e
#   bundle exec rake e2e

$stdout.sync = true

context = `kubectl config current-context 2>/dev/null`.strip
unless context.start_with?("kind-")
  abort "refusing to run the E2E suite: current kubectl context is #{context.inspect} " \
        "(a kind-* context is required so a personal kubeconfig is never targeted). " \
        "Create one with: kind create cluster --name k8s-rails-e2e"
end

require "k8s-rails"

prefix = "k8s-rails-e2e-#{Time.now.to_i}"
cm_name = "#{prefix}-cm"
pod_name = "#{prefix}-pod"

configmap = K8sRails.crd(group: "", version: "v1", plural: "configmaps", kind: "ConfigMap", readonly: false)
pod = K8sRails.crd(group: "", version: "v1", plural: "pods", kind: "Pod", readonly: false)
node = K8sRails.crd(group: "", version: "v1", plural: "nodes", kind: "Node", scope: :cluster)
namespace_res = K8sRails.crd(group: "", version: "v1", plural: "namespaces", kind: "Namespace", scope: :cluster)
deployment = K8sRails.crd(group: "apps", version: "v1", plural: "deployments", kind: "Deployment")

@failures = []

def check(label)
  yield
  puts "ok   #{label}"
rescue StandardError => e
  puts "FAIL #{label}: #{e.class}: #{e.message}"
  @failures << label
end

def gone(resource, name)
  resource.find_or_nil(name, namespace: "default")
end

connected = begin
  K8sRails.connected?
rescue StandardError => e
  abort "cannot connect to the API server (#{e.class}): #{e.message}"
end
abort "K8sRails.connected? returned false — the kind cluster is not reachable" unless connected

# Fresh-cluster readiness: the `default` ServiceAccount is created
# asynchronously AFTER the API server reports ready (measured on kind
# v0.22.0 / k8s v1.29.2: pod creation within seconds of `kind create
# cluster` fails with 403 "error looking up service account default/default:
# serviceaccount \"default\" not found", while ConfigMap writes succeed).
# Wait for it before the suite so the E2E is deterministic on a fresh cluster.
serviceaccount = K8sRails.crd(group: "", version: "v1", plural: "serviceaccounts", kind: "ServiceAccount")
sa_deadline = Time.now + 180
while serviceaccount.find_or_nil("default", namespace: "default").nil?
  raise "timed out waiting for the default ServiceAccount (fresh-cluster race)" if Time.now > sa_deadline

  puts "waiting for the default ServiceAccount (fresh-cluster race)..."
  sleep 2
end

begin
  # --- cluster-scoped + named-group reads (no residue) -----------------------
  check("nodes.list_cluster") { raise "no nodes found" if node.list_cluster.empty? }
  check("namespace.find_cluster(default)") { namespace_res.find_cluster("default") }
  check("deployment.list (named group)") { deployment.list }

  # --- ConfigMap: create / find / patch / immediate delete -> Status ---------
  check("configmap.create") do
    configmap.create({ metadata: { name: cm_name }, data: { "E2E" => "1" } }, namespace: "default")
  end
  check("configmap.find") do
    found = configmap.find(cm_name, namespace: "default")
    raise "value not written" unless found["data"] == { "E2E" => "1" }
  end
  check("configmap.patch") do
    configmap.patch(cm_name, [{ op: "replace", path: "/data/E2E", value: "2" }], namespace: "default")
  end
  status_response = nil
  check("configmap.delete -> Status response") do
    status_response = configmap.delete(cm_name, namespace: "default")
    unless status_response["kind"] == "Status" && status_response["status"] == "Success"
      raise "expected a Status response, got kind=#{status_response['kind'].inspect}"
    end
  end
  check("configmap gone") { raise "still present" unless gone(configmap, cm_name).nil? }

  # --- Pod: create / graceful delete -> the object itself --------------------
  check("pod.create") do
    pod.create(
      {
        apiVersion: "v1",
        kind: "Pod",
        metadata: { name: pod_name },
        spec: { containers: [{ name: "sleeper", image: "busybox:1.36", command: %w[sleep 300] }] }
      },
      namespace: "default"
    )
  end
  object_response = nil
  check("pod.delete -> the object itself") do
    object_response = pod.delete(pod_name, namespace: "default")
    unless object_response["kind"] == "Pod"
      raise "expected the Pod object back, got kind=#{object_response['kind'].inspect}"
    end
    raise "no deletionTimestamp in the delete response" unless object_response.dig("metadata", "deletionTimestamp")
  end
  check("pod gone (graceful wait)") do
    90.times do
      break if gone(pod, pod_name).nil?

      sleep 2
    end
    raise "pod still present after the wait" unless gone(pod, pod_name).nil?
  end

  if @failures.empty?
    puts "E2E OK (#{prefix})"
  else
    puts "E2E FAILED: #{@failures.join(', ')}"
  end
  exit @failures.empty? ? 0 : 1
ensure
  # Best-effort cleanup even on failure: NotFound means already gone.
  [[configmap, cm_name], [pod, pod_name]].each do |resource, name|
    resource.delete(name, namespace: "default")
  rescue K8sRails::NotFound
    nil
  end
end
