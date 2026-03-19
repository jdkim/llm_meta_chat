class Chat < ApplicationRecord
  include ChatManager::TitleGeneratable

  belongs_to :user, optional: true
  has_many :messages, dependent: :destroy

  before_create :set_uuid

  validates :llm_uuid, presence: true
  validates :model, presence: true

  # Find existing chat from session or create new one
  class << self
    def find_or_switch_for_session(session, current_user, llm_uuid: nil, model: nil)
      chat = find_by_session_chat_id(session, current_user)
      return chat if llm_uuid.nil? || model.nil?

      # Create new chat if it doesn't exist or LLM/model has changed
      if llm_uuid.present? && model.present? && (chat.nil? || (chat.present? && chat.needs_reset?(llm_uuid, model)))
        chat = create!(
          user: current_user,
          llm_uuid: llm_uuid,
          model: model
        )
        session[:chat_id] = chat.id
      end

      chat
    end

    private

    def find_by_session_chat_id(session, current_user)
      return nil unless session[:chat_id].present?

      if current_user.present?
        includes(:messages).find_by(id: session[:chat_id], user_id: current_user.id)
      else
        includes(:messages).find_by(id: session[:chat_id], user_id: nil)
      end
    end
  end

  # Get the LLM type for this chat
  def llm_type(jwt_token)
    llm_options = LlmMetaClient::ServerResource.available_llm_options(jwt_token)
    selected_llm = llm_options.find { |opt| opt[:uuid] == llm_uuid }
    selected_llm&.dig(:llm_type) || "unknown"
  end

  # Add a user message to the chat
  def add_user_message(message, model, branch_from_uuid = nil)
    parent_message = branch_from_uuid.present? ? messages.find_by(uuid: branch_from_uuid) : nil
    prompt_execution = PromptNavigator::PromptExecution.create!(
      prompt: message,
      model: model,
      configuration: "",
      previous_id: parent_message&.prompt_navigator_prompt_execution_id
    )

    new_message = messages.create!(
      role: "user",
      prompt_navigator_prompt_execution: prompt_execution
    )

    [ prompt_execution, new_message ]
  end

  # Add assistant response by sending to LLM
  def add_assistant_response(prompt_execution, jwt_token, tool_ids: [], generation_settings: {})
    response_content = send_to_llm(jwt_token, tool_ids: tool_ids, generation_settings: generation_settings)
    prompt_execution.update!(
      llm_platform: llm_type(jwt_token),
      response: response_content
    )
    new_message = messages.create!(
      role: "assistant",
      prompt_navigator_prompt_execution: prompt_execution
    )

    new_message
  end

  # Get all messages in order
  def ordered_messages
    messages
      .includes(:prompt_navigator_prompt_execution)
      .order(:created_at)
  end

  def ordered_by_descending_prompt_executions
    messages
      .where(role: "user")
      .includes(:prompt_navigator_prompt_execution)
      .order(created_at: :desc)
      .to_a
      .select { |msg| msg.prompt_navigator_prompt_execution }
      .map(&:prompt_navigator_prompt_execution)
  end

  # Check if chat needs to be reset due to LLM or model change
  def needs_reset?(new_llm_uuid, new_model)
    llm_uuid != new_llm_uuid || model != new_model
  end

  private

  # Summarize the user's prompt into a short title via LLM (required by ChatManager::TitleGeneratable)
  def summarize_for_title(prompt_text, jwt_token)
    LlmMetaClient::ServerQuery.new.call(
      jwt_token,
      llm_uuid,
      model,
      "No context available.",
      { role: "user", prompt: "Please summarize the following text into a short title (max 50 characters). Respond with only the title, nothing else: #{prompt_text}" }
    )
  end

  # Set a new UUID
  def set_uuid
    self.uuid = SecureRandom.uuid
  end

  # Send messages to LLM and get response
  def send_to_llm(jwt_token, tool_ids: [], generation_settings: {})
    # Get LLM options
    llm_options = LlmMetaClient::ServerResource.available_llm_options(jwt_token)

    # Error if no LLM is available
    raise LlmMetaClient::Exceptions::OllamaUnavailableError, "No LLM available" if llm_options.empty?

    # Build prompt and context from direct lineage via PromptExecution
    last_msg = ordered_messages.last
    pe = last_msg.prompt_navigator_prompt_execution

    prompt = { role: last_msg.role, prompt: pe.prompt }
    context = pe.build_context(limit: Rails.configuration.summarize_conversation_count)

    if context.empty?
      summarized_context = "No context available."
    else
      summarized_context = LlmMetaClient::ServerQuery.new.call(jwt_token, llm_uuid, model, context, "Please summarize the context")
    end

    summarized_context += "Additional prompt: Responses from the assistant must consist solely of the response body."

    # Send chat request using LlmMetaClient::ServerQuery
    LlmMetaClient::ServerQuery.new.call(jwt_token, llm_uuid, model, summarized_context, prompt, tool_ids: tool_ids, generation_settings: generation_settings)
  end
end
