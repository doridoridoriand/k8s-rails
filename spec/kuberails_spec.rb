# frozen_string_literal: true

require "spec_helper"

RSpec.describe KubeRails do
  it "exposes a version number" do
    expect(described_class::VERSION).to eq("0.1.0")
  end

  it "does not require kruby at load time (lazy, §3 data-flow principle)" do
    # Only lib/kuberails/client.rb may require "kubernetes" (§7).
    expect($LOADED_FEATURES.grep(%r{/kubernetes\.rb})).to be_empty
  end
end
