# frozen_string_literal: true

require "spec_helper"

RSpec.describe KubeRails do
  it "exposes a version number" do
    expect(described_class::VERSION).to eq("0.1.0")
  end

  it "does not require kruby at load time (lazy, §3 data-flow principle)" do
    # Only lib/kuberails/client.rb may require "kubernetes" (§7).
    # Verified in a FRESH subprocess: a process-global $LOADED_FEATURES check
    # would falsely fail once client specs (M1) load kruby in-process.
    code = "require \"kuberails\"; " \
           "puts($LOADED_FEATURES.grep(%r{kubernetes\.rb$}).empty?)"
    out = `echo '#{code}' | #{RbConfig.ruby} -Ilib -`.strip
    expect(out).to eq("true")
  end

  it "allows direct KubeRails::Client access (autoload, §5.2 public entry)" do
    # Copilot P2 (#4056821923): the documented entry `KubeRails::Client.build`
    # must work after a plain `require "kuberails"` — previously a NameError
    # because Client was only defined via KubeRails.client / connected?.
    # Verified in a fresh subprocess (references Client → loads kruby).
    code = "require \"kuberails\"; " \
           "puts(KubeRails.const_defined?(:Client, false)); " \
           "puts($LOADED_FEATURES.grep(%r{kubernetes\.rb$}).empty?); " \
           "puts(KubeRails::Client.is_a?(Module)); " \
           "puts($LOADED_FEATURES.grep(%r{kubernetes\.rb$}).any?)"
    out = `echo '#{code}' | #{RbConfig.ruby} -Ilib -`.strip
    expect(out).to eq("true\ntrue\ntrue\ntrue")
  end
end
