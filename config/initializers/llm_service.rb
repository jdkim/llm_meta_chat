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
  config.default_model = ENV["LLM_DEFAULT_MODEL"] ||
                         Rails.application.credentials.dig(:llm_service, :default_model) ||
                         "qwen3-6-35b-fast"

  # Cheap meta_id used by Chat#summarization_target to condense overflow
  # context. Falls back to the user's selected model if this meta_id isn't
  # in the catalog at request time.
  config.summarization_model = ENV["LLM_SUMMARIZATION_MODEL"] ||
                               Rails.application.credentials.dig(:llm_service, :summarization_model) ||
                               "qwen3-6-35b-fast"
end
