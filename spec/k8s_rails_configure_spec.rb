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

    # #16: a raising block must NOT lock in a "configured" state — a later
    # configure call is allowed to run (and actually applies) normally.
    it "allows a later configure after the block raised (#16)" do
      expect do
        K8sRails.configure do |c|
          c.namespace = "partial"
          raise "initializer failed"
        end
      end.to raise_error(RuntimeError, "initializer failed")

      # No warning: the failed call does not count as "already configured".
      expect(K8sRails).not_to receive(:warn)
      K8sRails.configure { |c| c.namespace = "retry" }
      expect(K8sRails.config.namespace).to eq("retry")
    end

    it "still warns on a third call after a failed one was followed by a success (#16)" do
      begin
        K8sRails.configure { raise "boom" } # failed — does not count
      rescue RuntimeError
        nil
      end
      K8sRails.configure { |c| c.namespace = "ok" }

      expect(K8sRails).to receive(:warn).with(/more than once/)
      K8sRails.configure { |c| c.namespace = "third" }
      expect(K8sRails.config.namespace).to eq("ok")
    end

    # Documented contract (#16): attribute writes made before the raise
    # REMAIN on the shared Configuration. The re-run block must set all the
    # attributes it depends on.
    it "leaves pre-raise attribute writes in place (documented partial-state contract, #16)" do
      begin
        K8sRails.configure do |c|
          c.namespace = "partial"
          raise "initializer failed"
        end
      rescue RuntimeError
        nil
      end

      # A successful re-run that does not touch namespace keeps the partial value.
      K8sRails.configure { |c| c.instrumentation = false }
      expect(K8sRails.config.namespace).to eq("partial")
      expect(K8sRails.config.instrumentation).to be(false)
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
