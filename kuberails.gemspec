# frozen_string_literal: true

require_relative "lib/kuberails/version"

Gem::Specification.new do |spec|
  spec.name = "kuberails"
  spec.version = KubeRails::VERSION
  spec.authors = ["Dorian - Takahiro Ishida"]
  spec.email = ["i.am.eager.for.peace@gmail.com"]

  spec.summary = "Kubernetes API / CRD convention layer for Rails applications"
  spec.description =
    "kuberails provides the connection / CRD access / error-handling " \
    "convention layer for Rails applications talking to the Kubernetes API, as a gem."
  spec.homepage = "https://github.com/doridoridoriand/kuberails"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE", "docs/design.md"]
  spec.require_paths = ["lib"]

  # kruby (official Kubernetes OpenAPI client). Pinned to the 1.36.x line;
  # see docs/design.md §6 (why ~> 1.36.0, not ~> 1.36).
  spec.add_dependency "kruby", "~> 1.36.0"

  # Optional at runtime (guarded via defined?(ActiveSupport::Notifications) in §8).
  # Development dependency so specs can exercise the instrumentation path.
  spec.add_development_dependency "activesupport", ">= 7.0"
  spec.add_development_dependency "rake", ">= 13.0"
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rubocop", ">= 1.60"
end
