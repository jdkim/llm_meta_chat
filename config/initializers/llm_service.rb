# frozen_string_literal: true

# LLM Service Configuration
# External LLM service base URL for API key and model management
Rails.application.configure do
  # Base URL for LLM service
  # Retrieved from Rails credentials, uses default value if not set
  config.llm_service_base_url = ENV["LLM_SERVICE_BASE_URL"] ||
                                Rails.application.credentials.dig(:llm_service, :base_url) ||
                                "http://localhost:3000"
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
