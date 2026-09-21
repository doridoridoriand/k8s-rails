# frozen_string_literal: true

require "spec_helper"

RSpec.describe K8sRails do
  describe ".configure" do
    it "applies settings once" do
      K8sRails.configure { |c| c.namespace = "ns-1" }
      expect(K8sRails.config.namespace).to eq("ns-1")
    end

    it "ignores a second configure call and warns" do
      K8sRails.configure { |c| c.namespace = "first" }
      expect(K8sRails).to receive(:warn).with(/more than once/)
      K8sRails.configure { |c| c.namespace = "second" }
      expect(K8sRails.config.namespace).to eq("first")
    end

    after { K8sRails.reset! }
  end

  describe ".reset!" do
    it "clears configuration back to defaults" do
      K8sRails.configure { |c| c.namespace = "gone" }
      K8sRails.reset!
      expect(K8sRails.config.namespace).to eq("default")
    end

    it "discards the cached transport so a later build re-resolves" do
      fake = Class.new do
        def list_namespaced_custom_object(*)
          { tag: "injected" }
        end
      end.new
      K8sRails.reset!
      K8sRails.config.api_client = fake
      expect(K8sRails.client.list("g", "v", "n", "p")).to eq("tag" => "injected")

      K8sRails.reset!
      expect(K8sRails.config.api_client).to be_nil
    end
  end
end
