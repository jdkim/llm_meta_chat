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
end
