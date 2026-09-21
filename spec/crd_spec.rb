# frozen_string_literal: true

require "spec_helper"

RSpec.describe "K8sRails.crd" do
  before { K8sRails.reset! }

  it "returns a Resource subclass with the declared coordinates bound" do
    wf = K8sRails.crd(
      group: "argoproj.io",
      version: "v1alpha1",
      plural: "workflows",
      kind: "Workflow"
    )

    expect(wf).to be_a(Class)
    expect(wf).to be < K8sRails::Resource
    expect(wf.group_name).to eq("argoproj.io")
    expect(wf.version_name).to eq("v1alpha1")
    expect(wf.plural_name).to eq("workflows")
    expect(wf.kind_name).to eq("Workflow")
    expect(wf.declared_namespace).to be_nil
    expect(wf.readonly?).to be(true)
  end

  it "binds namespace and readonly when provided" do
    wf = K8sRails.crd(
      group: "g", version: "v1", plural: "p", kind: "K",
      namespace: "prod", readonly: false
    )

    expect(wf.declared_namespace).to eq("prod")
    expect(wf.readonly?).to be(false)
  end

  it "registers the class under its kind (K5: explicit, never guessed)" do
    wf = K8sRails.crd(group: "g", version: "v1", plural: "workflows", kind: "Workflow")

    expect(K8sRails::CRD.registered).to eq("Workflow" => wf)
  end

  it "rejects a non-boolean readonly (mutations require an explicit false, K4)" do
    expect do
      K8sRails.crd(group: "g", version: "v1", plural: "p", kind: "NilRO", readonly: nil)
    end.to raise_error(ArgumentError, /readonly must be true or false/)

    # nil must NOT have silently enabled writes (the pre-fix fail-open).
    expect(K8sRails::CRD.registered).not_to have_key("NilRO")
  end

  it "raises RedeclarationError on a second declaration of the same kind" do
    K8sRails.crd(group: "g", version: "v1", plural: "p", kind: "Widget")

    expect do
      K8sRails.crd(group: "g", version: "v2", plural: "p", kind: "Widget")
    end.to raise_error(K8sRails::RedeclarationError, /already declared/)
  end

  it "allows distinct kinds in the same group" do
    K8sRails.crd(group: "g", version: "v1", plural: "a", kind: "A")
    K8sRails.crd(group: "g", version: "v1", plural: "b", kind: "B")

    expect(K8sRails::CRD.registered.keys).to contain_exactly("A", "B")
  end

  it "is cleared by K8sRails.reset! (test support)" do
    K8sRails.crd(group: "g", version: "v1", plural: "p", kind: "Gone")
    K8sRails.reset!

    expect(K8sRails::CRD.registered).to be_empty
  end

  it "accepts scope: :cluster and binds it (cluster-scoped CRDs, #17)" do
    ci = K8sRails.crd(
      group: "cert-manager.io", version: "v1", plural: "clusterissuers",
      kind: "ClusterIssuer", scope: :cluster
    )

    expect(ci.cluster_scoped?).to be(true)
    expect(ci.declared_namespace).to be_nil
  end

  it "defaults to scope: :namespaced" do
    wf = K8sRails.crd(group: "g", version: "v1", plural: "workflows", kind: "Workflow")
    expect(wf.cluster_scoped?).to be(false)
  end

  it "rejects an unknown scope (fail fast)" do
    expect do
      K8sRails.crd(group: "g", version: "v1", plural: "p", kind: "BadScope", scope: :global)
    end.to raise_error(ArgumentError, /scope must be :namespaced or :cluster/)

    expect(K8sRails::CRD.registered).not_to have_key("BadScope")
  end

  it "rejects namespace: combined with scope: :cluster (#17)" do
    expect do
      K8sRails.crd(group: "g", version: "v1", plural: "clusterp", kind: "BadCombo",
                   scope: :cluster, namespace: "team-a")
    end.to raise_error(ArgumentError, /namespace cannot be combined with scope: :cluster/)

    expect(K8sRails::CRD.registered).not_to have_key("BadCombo")
  end

  it "does not load kruby at declaration time (§7 lazy contract)" do
    code = "require \"k8s-rails\"; " \
           "K8sRails.crd(group: \"g\", version: \"v1\", plural: \"p\", kind: \"K\"); " \
           "puts($LOADED_FEATURES.grep(%r{kubernetes\\.rb$}).empty?)"
    out = `echo '#{code}' | #{RbConfig.ruby} -Ilib -`.strip
    expect(out).to eq("true")
  end
end
