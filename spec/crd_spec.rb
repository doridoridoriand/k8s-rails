# frozen_string_literal: true

require "spec_helper"

RSpec.describe "KubeRails.crd" do
  before { KubeRails.reset! }

  it "returns a Resource subclass with the declared coordinates bound" do
    wf = KubeRails.crd(
      group: "argoproj.io",
      version: "v1alpha1",
      plural: "workflows",
      kind: "Workflow"
    )

    expect(wf).to be_a(Class)
    expect(wf).to be < KubeRails::Resource
    expect(wf.group_name).to eq("argoproj.io")
    expect(wf.version_name).to eq("v1alpha1")
    expect(wf.plural_name).to eq("workflows")
    expect(wf.kind_name).to eq("Workflow")
    expect(wf.declared_namespace).to be_nil
    expect(wf.readonly?).to be(true)
  end

  it "binds namespace and readonly when provided" do
    wf = KubeRails.crd(
      group: "g", version: "v1", plural: "p", kind: "K",
      namespace: "prod", readonly: false
    )

    expect(wf.declared_namespace).to eq("prod")
    expect(wf.readonly?).to be(false)
  end

  it "registers the class under its kind (K5: explicit, never guessed)" do
    wf = KubeRails.crd(group: "g", version: "v1", plural: "workflows", kind: "Workflow")

    expect(KubeRails::CRD.registered).to eq("Workflow" => wf)
  end

  it "raises RedeclarationError on a second declaration of the same kind" do
    KubeRails.crd(group: "g", version: "v1", plural: "p", kind: "Widget")

    expect do
      KubeRails.crd(group: "g", version: "v2", plural: "p", kind: "Widget")
    end.to raise_error(KubeRails::RedeclarationError, /already declared/)
  end

  it "allows distinct kinds in the same group" do
    KubeRails.crd(group: "g", version: "v1", plural: "a", kind: "A")
    KubeRails.crd(group: "g", version: "v1", plural: "b", kind: "B")

    expect(KubeRails::CRD.registered.keys).to contain_exactly("A", "B")
  end

  it "is cleared by KubeRails.reset! (test support)" do
    KubeRails.crd(group: "g", version: "v1", plural: "p", kind: "Gone")
    KubeRails.reset!

    expect(KubeRails::CRD.registered).to be_empty
  end

  it "does not load kruby at declaration time (§7 lazy contract)" do
    code = "require \"kuberails\"; " \
           "KubeRails.crd(group: \"g\", version: \"v1\", plural: \"p\", kind: \"K\"); " \
           "puts($LOADED_FEATURES.grep(%r{kubernetes\\.rb$}).empty?)"
    out = `echo '#{code}' | #{RbConfig.ruby} -Ilib -`.strip
    expect(out).to eq("true")
  end
end
