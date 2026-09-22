# frozen_string_literal: true

require "spec_helper"

RSpec.describe K8sRails do
  it "exposes a version number" do
    expect(described_class::VERSION).to eq("0.3.0")
  end

  it "does not require kruby at load time (lazy, §3 data-flow principle)" do
    # Only lib/k8s_rails/client.rb may require "kubernetes" (§7).
    # Verified in a FRESH subprocess: a process-global $LOADED_FEATURES check
    # would falsely fail once client specs (M1) load kruby in-process.
    code = "require \"k8s-rails\"; " \
           "puts($LOADED_FEATURES.grep(%r{kubernetes\.rb$}).empty?)"
    out = `echo '#{code}' | #{RbConfig.ruby} -Ilib -`.strip
    expect(out).to eq("true")
  end

  it "allows direct K8sRails::Client access (autoload, §5.2 public entry)" do
    # Copilot P2 (#4056821923): the documented entry `K8sRails::Client.build`
    # must work after a plain `require "k8s-rails"` — previously a NameError
    # because Client was only defined via K8sRails.client / connected?.
    # Verified in a fresh subprocess (references Client → loads kruby).
    code = "require \"k8s-rails\"; " \
           "puts(K8sRails.const_defined?(:Client, false)); " \
           "puts($LOADED_FEATURES.grep(%r{kubernetes\.rb$}).empty?); " \
           "puts(K8sRails::Client.is_a?(Module)); " \
           "puts($LOADED_FEATURES.grep(%r{kubernetes\.rb$}).any?)"
    out = `echo '#{code}' | #{RbConfig.ruby} -Ilib -`.strip
    expect(out).to eq("true\ntrue\ntrue\ntrue")
  end
end
