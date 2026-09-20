# frozen_string_literal: true

require "spec_helper"

RSpec.describe KubeRails::Normalizer do
  describe ".stringify" do
    it "converts a flat hash of symbol keys to string keys" do
      expect(described_class.stringify(name: "wf", ready: true)).to eq("name" => "wf", "ready" => true)
    end

    it "recurses into nested hashes" do
      src = { metadata: { name: "wf", labels: { app: "x" } } }
      expect(described_class.stringify(src)).to eq(
        "metadata" => { "name" => "wf", "labels" => { "app" => "x" } }
      )
    end

    it "maps arrays of objects" do
      src = { items: [{ name: "a" }, { name: "b" }] }
      expect(described_class.stringify(src)).to eq(
        "items" => [{ "name" => "a" }, { "name" => "b" }]
      )
    end

    it "leaves non-Hash/Array values unchanged" do
      expect(described_class.stringify("x")).to eq("x")
      expect(described_class.stringify(3)).to eq(3)
      expect(described_class.stringify(nil)).to be_nil
      expect(described_class.stringify(true)).to be(true)
    end

    it "does not mutate the input" do
      src = { a: { b: 1 } }
      described_class.stringify(src)
      expect(src).to eq(a: { b: 1 })
    end

    it "keeps existing string keys as-is" do
      expect(described_class.stringify("a" => 1)).to eq("a" => 1)
    end
  end
end
