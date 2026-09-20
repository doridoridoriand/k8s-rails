# frozen_string_literal: true

require "spec_helper"

RSpec.describe KubeRails::Configuration do
  describe "defaults" do
    it "sets namespace to default" do
      expect(described_class.new.namespace).to eq("default")
    end

    it "starts with no connection override" do
      expect(described_class.new.connection).to be_nil
    end

    it "starts with no injected api_client" do
      expect(described_class.new.api_client).to be_nil
    end

    it "has instrumentation on by default" do
      expect(described_class.new.instrumentation).to be(true)
    end
  end
end
