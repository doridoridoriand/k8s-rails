# frozen_string_literal: true

require "spec_helper"
require "k8s_rails/client"
require "active_support"

# Design §8: `k8s-rails.request` notifications.
RSpec.describe "K8sRails.instrument" do
  before do
    K8sRails.reset!
    @fake = RecordingTransport.new
    K8sRails.config.api_client = @fake
    @events = []
    @sub = ActiveSupport::Notifications.subscribe("k8s-rails.request") do |*args|
      # args: [name, started, finished, unique_id, payload]
      @events << [args[0], args[4]]
    end
  end

  after do
    ActiveSupport::Notifications.unsubscribe(@sub)
  end

  def declare(namespace: "team-a")
    K8sRails.crd(group: "argoproj.io", version: "v1alpha1", plural: "workflows",
                 kind: "Workflow", namespace:)
  end

  it "emits k8s-rails.request with §8 payload on success (instrumentation: true)" do
    K8sRails.config.instrumentation = true
    wf = declare

    out = wf.list

    expect(out).not_to be_empty # return value flows through
    expect(@events.size).to eq(1)
    name, payload = @events.first
    expect(name).to eq("k8s-rails.request")
    expect(payload[:operation]).to eq(:list)
    expect(payload[:group]).to eq("argoproj.io")
    expect(payload[:version]).to eq("v1alpha1")
    expect(payload[:plural]).to eq("workflows")
    expect(payload[:namespace]).to eq("team-a")
    expect(payload[:status]).to eq("ok")
    expect(payload[:duration_ms]).to be_a(Numeric)
    expect(payload[:duration_ms]).to be >= 0
    # Standard AS metadata is absent on the success path (#32).
    expect(payload.key?(:exception)).to be(false)
    expect(payload.key?(:exception_object)).to be(false)
  end

  it "brackets the API call with the standard event start/finish times" do
    K8sRails.config.instrumentation = true
    slow = Class.new(RecordingTransport) do
      def call_api(*args)
        sleep(0.05)
        super
      end
    end.new
    K8sRails.config.api_client = slow
    wf = declare

    span_ms = nil
    sub = ActiveSupport::Notifications.subscribe("k8s-rails.request") do |*args|
      span_ms = ((args[2] - args[1]) * 1_000).round(2)
    end
    wf.list
    ActiveSupport::Notifications.unsubscribe(sub)

    # The transport sleeps 50ms; the standard event span must cover the real
    # processing with generous CI tolerance (lower bound only — slower is fine).
    expect(span_ms).to be >= 40.0
    expect(@events.first[1][:duration_ms]).to be >= 40.0
    expect(@events.size).to eq(1)
  end

  it "reports status api_error and re-raises on 404" do
    K8sRails.config.instrumentation = true
    wf = declare
    @fake.raise_on_get = Kubernetes::ApiError.new(code: 404, response_body: nil)

    raised = nil
    expect { wf.find("missing") }.to raise_error(K8sRails::NotFound) { |error| raised = error }
    expect(@events.size).to eq(1)
    expect(@events.first[1][:status]).to eq("api_error")
    expect(@events.first[1][:operation]).to eq(:find)
    # The finish event fires after the block raises: the standard AS exception
    # metadata rides along with the custom status (#32), and the raised
    # exception is the very object the transport raised.
    expect(@events.first[1][:exception]).to eq(["K8sRails::NotFound", raised.message])
    expect(@events.first[1][:exception_object]).to equal(raised)
  end

  it "reports status unavailable and re-raises on transport failure (code 0)" do
    K8sRails.config.instrumentation = true
    wf = declare
    @fake.raise_on_get = Kubernetes::ApiError.new(code: 0, response_body: nil)

    expect { wf.find("x") }.to raise_error(K8sRails::Unavailable)
    expect(@events.first[1][:status]).to eq("unavailable")
    expect(@events.first[1][:exception][0]).to eq("K8sRails::Unavailable")
  end

  it "falls back to status api_error for exceptions outside the K8sRails hierarchy" do
    K8sRails.config.instrumentation = true
    bad = Class.new do
      def call_api(*) = raise NoMethodError, "malformed stub"
    end.new
    K8sRails.config.api_client = bad
    wf = declare

    raised = nil
    expect { wf.list }.to raise_error(NoMethodError) { |error| raised = error }
    expect(@events.size).to eq(1)
    expect(@events.first[1][:status]).to eq("api_error")
    expect(@events.first[1][:exception]).to eq(["NoMethodError", "malformed stub"])
    expect(@events.first[1][:exception_object]).to equal(raised)
  end

  it "is a no-op when instrumentation is explicitly disabled" do
    K8sRails.config.instrumentation = false
    wf = declare
    wf.list

    expect(@events).to be_empty
  end

  it "is a no-op when ActiveSupport is not loaded (simulated)" do
    K8sRails.config.instrumentation = true
    wf = declare
    allow(K8sRails).to receive(:instrumentation_enabled?).and_return(false)

    out = wf.list

    expect(out).not_to be_empty
    expect(@events).to be_empty
  end

  it "wraps create/patch/delete calls with the operation name" do
    K8sRails.config.instrumentation = true
    writable = K8sRails.crd(group: "g", version: "v1", plural: "p", kind: "W",
                            namespace: "default", readonly: false)

    writable.create({ metadata: { name: "w" } })
    writable.patch("w", [{ "op" => "replace", "path" => "/spec/a", "value" => 1 }])
    writable.delete("w")

    expect(@events.map { |e| e[1][:operation] }).to eq(%i[create patch delete])
    expect(@events.all? { |e| e[1][:status] == "ok" }).to be(true)
  end

  it "wraps delete_cluster calls with the operation name" do
    K8sRails.config.instrumentation = true
    cluster_writable = K8sRails.crd(group: "g", version: "v1", plural: "c", kind: "C",
                                    scope: :cluster, readonly: false)

    cluster_writable.delete_cluster("c-1")

    expect(@events.map { |e| e[1][:operation] }).to eq(%i[delete])
    expect(@events.first[1][:namespace]).to be_nil
    expect(@events.first[1][:status]).to eq("ok")
  end
end
