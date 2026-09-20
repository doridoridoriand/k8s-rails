# frozen_string_literal: true

require "spec_helper"
require "kuberails/client"
require "active_support"

# Design §8: `kuberails.request` notifications.
RSpec.describe "KubeRails.instrument" do
  before do
    KubeRails.reset!
    @fake = RecordingTransport.new
    KubeRails.config.api_client = @fake
    @events = []
    @sub = ActiveSupport::Notifications.subscribe("kuberails.request") do |*args|
      # args: [name, started, finished, unique_id, payload]
      @events << [args[0], args[4]]
    end
  end

  after do
    ActiveSupport::Notifications.unsubscribe(@sub)
  end

  def declare(namespace: "team-a")
    KubeRails.crd(group: "argoproj.io", version: "v1alpha1", plural: "workflows",
                  kind: "Workflow", namespace:)
  end

  it "emits kuberails.request with §8 payload on success (instrumentation: true)" do
    KubeRails.config.instrumentation = true
    wf = declare

    out = wf.list

    expect(out).not_to be_empty # return value flows through
    expect(@events.size).to eq(1)
    name, payload = @events.first
    expect(name).to eq("kuberails.request")
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
    KubeRails.config.instrumentation = true
    wf = declare
    @fake.raise_on_get = Kubernetes::ApiError.new(code: 404, response_body: nil)

    expect { wf.find("missing") }.to raise_error(KubeRails::NotFound)
    expect(@events.size).to eq(1)
    expect(@events.first[1][:status]).to eq("api_error")
    expect(@events.first[1][:operation]).to eq(:find)
  end

  it "reports status unavailable and re-raises on transport failure (code 0)" do
    KubeRails.config.instrumentation = true
    wf = declare
    @fake.raise_on_get = Kubernetes::ApiError.new(code: 0, response_body: nil)

    expect { wf.find("x") }.to raise_error(KubeRails::Unavailable)
    expect(@events.first[1][:status]).to eq("unavailable")
  end

  it "is a no-op when instrumentation is explicitly disabled" do
    KubeRails.config.instrumentation = false
    wf = declare
    wf.list

    expect(@events).to be_empty
  end

  it "is a no-op when ActiveSupport is not loaded (simulated)" do
    KubeRails.config.instrumentation = true
    wf = declare
    allow(KubeRails).to receive(:instrumentation_enabled?).and_return(false)

    out = wf.list

    expect(out).not_to be_empty
    expect(@events).to be_empty
  end

  it "wraps create/patch calls with the operation name" do
    KubeRails.config.instrumentation = true
    writable = KubeRails.crd(group: "g", version: "v1", plural: "p", kind: "W",
                             namespace: "default", readonly: false)

    writable.create({ metadata: { name: "w" } })
    writable.patch("w", [{ "op" => "replace", "path" => "/spec/a", "value" => 1 }])

    expect(@events.map { |e| e[1][:operation] }).to eq(%i[create patch])
    expect(@events.all? { |e| e[1][:status] == "ok" }).to be(true)
  end
end
