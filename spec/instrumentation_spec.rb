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
  end

  it "reports status api_error and re-raises on 404" do
    K8sRails.config.instrumentation = true
    wf = declare
    @fake.raise_on_get = Kubernetes::ApiError.new(code: 404, response_body: nil)

    expect { wf.find("missing") }.to raise_error(K8sRails::NotFound)
    expect(@events.size).to eq(1)
    expect(@events.first[1][:status]).to eq("api_error")
    expect(@events.first[1][:operation]).to eq(:find)
  end

  it "reports status unavailable and re-raises on transport failure (code 0)" do
    K8sRails.config.instrumentation = true
    wf = declare
    @fake.raise_on_get = Kubernetes::ApiError.new(code: 0, response_body: nil)

    expect { wf.find("x") }.to raise_error(K8sRails::Unavailable)
    expect(@events.first[1][:status]).to eq("unavailable")
  end

  it "falls back to status api_error for exceptions outside the K8sRails hierarchy" do
    K8sRails.config.instrumentation = true
    bad = Class.new do
      def call_api(*) = raise NoMethodError, "malformed stub"
    end.new
    K8sRails.config.api_client = bad
    wf = declare

    expect { wf.list }.to raise_error(NoMethodError)
    expect(@events.size).to eq(1)
    expect(@events.first[1][:status]).to eq("api_error")
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

  it "wraps create/patch calls with the operation name" do
    K8sRails.config.instrumentation = true
    writable = K8sRails.crd(group: "g", version: "v1", plural: "p", kind: "W",
                            namespace: "default", readonly: false)

    writable.create({ metadata: { name: "w" } })
    writable.patch("w", [{ "op" => "replace", "path" => "/spec/a", "value" => 1 }])

    expect(@events.map { |e| e[1][:operation] }).to eq(%i[create patch])
    expect(@events.all? { |e| e[1][:status] == "ok" }).to be(true)
  end
end
