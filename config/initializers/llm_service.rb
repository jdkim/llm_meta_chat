# frozen_string_literal: true

# LLM Service Configuration
# External LLM service base URL for API key and model management
Rails.application.configure do
  # Base URL for LLM service — used for SERVER-SIDE HTTP calls from
  # this app to the meta-server (ServerResource / ServerQuery). On a
  # same-box deployment this should be the loopback URL so traffic
  # doesn't bounce through the public proxy and hit SSE buffering.
  config.llm_service_base_url = ENV["LLM_SERVICE_BASE_URL"] ||
                                Rails.application.credentials.dig(:llm_service, :base_url) ||
                                "http://localhost:3000"

  # Public URL for the LLM service — used in BROWSER-FACING links
  # (e.g., "Manage API keys" in the model picker footer). May differ
  # from `llm_service_base_url` when internal calls go over loopback
  # but the user's browser needs a public hostname. Defaults to the
  # base URL when not separately set.
  config.llm_service_public_url = ENV["LLM_SERVICE_PUBLIC_URL"] ||
                                  Rails.application.credentials.dig(:llm_service, :public_url) ||
                                  config.llm_service_base_url

  config.summarize_conversation_count = (Rails.application.credentials.dig(:llm_service, :summarize_conversation_count) || 10).to_i

  # System-wide default meta_id pre-selected in the chat composer.
  # Override via LLM_DEFAULT_MODEL or credentials[:llm_service][:default_model].
  # Keep this pointing at a model that is actually in the catalog. It named
  # qwen3-6-35b-fast until that model was retired (2026-09-05), after which
  # the composer silently had no pre-selected model at all — nothing warns
  # when the default names something the catalog no longer serves.
  config.default_model = ENV["LLM_DEFAULT_MODEL"] ||
                         Rails.application.credentials.dig(:llm_service, :default_model) ||
                         "qwen3-8-27b-fast"

  # Cheap meta_id used by Chat#summarization_target to condense overflow
  # context. Falls back to the user's selected model if this meta_id isn't
  # in the catalog at request time.
  # Same model as the default: it is the non-thinking variant of the one
  # already resident on the local server, so summarising costs no extra load
  # and no model swap.
  config.summarization_model = ENV["LLM_SUMMARIZATION_MODEL"] ||
                               Rails.application.credentials.dig(:llm_service, :summarization_model) ||
                               "qwen3-8-27b-fast"
end
