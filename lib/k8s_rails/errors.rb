# frozen_string_literal: true

module K8sRails
  # Base class for all K8sRails errors (K3, design §5.4).
  #
  # Apps rescue the specific subclass they care about, or `K8sRails::Error`
  # to catch everything this gem raises. Errors that are NOT wrapped (e.g.
  # programming errors like NoMethodError) propagate raw on purpose — we never
  # mask a bug as a K8s problem.
  class Error < StandardError; end

  # The cluster cannot be reached, or the connection/transport layer failed
  # (DNS failure, timeout, connection refused, TLS handshake error, etc.).
  #
  # In kruby 1.36.x these surface as `Kubernetes::ApiError` with `code == 0`
  # (the transport layer has no HTTP status). A small allowlist of low-level
  # network exceptions is also mapped here in case a future kruby/Typhoeus
  # release lets them escape raw (see Client::TRANSFER_LAYER_ERRORS).
  class Unavailable < Error; end

  # The requested resource does not exist (HTTP 404).
  class NotFound < Error; end

  # Any other Kubernetes API error (401/403/409/422/5xx, ...).
  # Carries the HTTP `#code` and the raw API `#response` body so callers can
  # inspect or display it.
  class ApiError < Error
    attr_reader :code, :response

    def initialize(code:, response: nil, message: nil)
      @code = code
      @response = response
      super(message || "Kubernetes API error (HTTP #{code})")
    end
  end

  # create/patch was called on a CRD declared with `readonly: true` (M2).
  # A configuration mistake — raised, never swallowed.
  class ReadOnlyError < Error; end

  # A CRD with the same name was declared twice (M2). A configuration mistake.
  class RedeclarationError < Error; end
end
