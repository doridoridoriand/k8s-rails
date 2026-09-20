# frozen_string_literal: true

require "spec_helper"

RSpec.describe KubeRails do
  describe ".configure" do
    it "applies settings once" do
      KubeRails.configure { |c| c.namespace = "ns-1" }
      expect(KubeRails.config.namespace).to eq("ns-1")
    end

    it "ignores a second configure call and warns" do
      KubeRails.configure { |c| c.namespace = "first" }
      expect(KubeRails).to receive(:warn).with(/more than once/)
      KubeRails.configure { |c| c.namespace = "second" }
      expect(KubeRails.config.namespace).to eq("first")
    end

    after { KubeRails.reset! }
  end

  describe ".reset!" do
    it "clears configuration back to defaults" do
      KubeRails.configure { |c| c.namespace = "gone" }
      KubeRails.reset!
      expect(KubeRails.config.namespace).to eq("default")
    end

    it "discards the cached transport so a later build re-resolves" do
      fake = Class.new do
        def list_namespaced_custom_object(*)
          { tag: "injected" }
        end
      end.new
      KubeRails.reset!
      KubeRails.config.api_client = fake
      expect(KubeRails.client.list("g", "v", "n", "p")).to eq("tag" => "injected")

      KubeRails.reset!
      expect(KubeRails.config.api_client).to be_nil
    end
  end
end
