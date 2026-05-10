class Chat < ApplicationRecord
  include ChatManager::TitleGeneratable

  belongs_to :user, optional: true
  has_many :messages, dependent: :destroy

  before_create :set_uuid

  # Find existing chat from session or create new one
  class << self
    def find_or_switch_for_session(session, current_user)
      chat = find_by_session_chat_id(session, current_user)
      return chat if chat.present?

      chat = create!(user: current_user)
      session[:chat_id] = chat.id
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

  # Add a user message to the chat
  def add_user_message(message, llm_uuid, model, branch_from_execution_id = nil)
    previous_id = if branch_from_execution_id.present?
      PromptNavigator::PromptExecution.find_by(execution_id: branch_from_execution_id)&.id
    else
      messages.where(role: "user").order(:created_at).last&.prompt_navigator_prompt_execution_id
    end
    prompt_execution = PromptNavigator::PromptExecution.create!(
      prompt: message,
      llm_uuid: llm_uuid,
      model: model,
      configuration: "",
      previous_id: previous_id
    )

    new_message = messages.create!(
      role: "user",
      prompt_navigator_prompt_execution: prompt_execution
    )

    [ prompt_execution, new_message ]
  end

  # Add assistant response by sending to LLM
  def add_assistant_response(prompt_execution, jwt_token, tool_ids: [], generation_settings: {})
    response_content = send_to_llm(prompt_execution, jwt_token, tool_ids: tool_ids, generation_settings: generation_settings)
    prompt_execution.update!(
      llm_platform: resolve_llm_type(prompt_execution.llm_uuid, jwt_token),
      response: response_content
    )
    new_message = messages.create!(
      role: "assistant",
      prompt_navigator_prompt_execution: prompt_execution
    )

    new_message
  end

  # Stream the assistant response from the LLM. Yields each parsed SSE event.
  # Returns the assembled content (with markdown "Tool calls" section appended
  # if tools fired). Caller is responsible for persistence.
  def stream_assistant_response(prompt_execution, jwt_token, tool_ids: [], generation_settings: {}, &block)
    summarized_context, prompt = build_streaming_context(prompt_execution, jwt_token, with_tools: tool_ids.any?)
    LlmMetaClient::ServerQuery.new.stream(
      jwt_token,
      prompt_execution.llm_uuid,
      prompt_execution.model,
      summarized_context,
      prompt,
      tool_ids: tool_ids,
      generation_settings: generation_settings,
      &block
    )
  end

  # Persist the streamed assistant response. Skips persistence if content is blank.
  def finalize_streamed_response(prompt_execution, content, jwt_token)
    return nil if content.blank?

    prompt_execution.update!(
      llm_platform: resolve_llm_type(prompt_execution.llm_uuid, jwt_token),
      response: content
    )
    messages.create!(
      role: "assistant",
      prompt_navigator_prompt_execution: prompt_execution
    )
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

  private

  # Resolve the LLM type (e.g. "openai", "google") from a given llm_uuid
  def resolve_llm_type(llm_uuid, jwt_token)
    llm_options = LlmMetaClient::ServerResource.available_llm_options(jwt_token)
    selected_llm = llm_options.find { |opt| opt[:uuid] == llm_uuid }
    selected_llm&.dig(:llm_type) || "unknown"
  end

  # Summarize the user's prompt into a short title via LLM (required by ChatManager::TitleGeneratable)
  def summarize_for_title(prompt_text, jwt_token)
    latest_pe = ordered_by_descending_prompt_executions.first
    return nil unless latest_pe&.llm_uuid && latest_pe&.model

    LlmMetaClient::ServerQuery.new.call(
      jwt_token,
      latest_pe.llm_uuid,
      latest_pe.model,
      "No context available.",
      { role: "user", prompt: "Please summarize the following text into a short title (max 50 characters). Respond with only the title, nothing else: #{prompt_text}" }
    )
  end

  # Set a new UUID
  def set_uuid
    self.uuid = SecureRandom.uuid
  end

  # Send messages to LLM and get response
  def send_to_llm(prompt_execution, jwt_token, tool_ids: [], generation_settings: {})
    summarized_context, prompt = build_streaming_context(prompt_execution, jwt_token, with_tools: tool_ids.any?)
    LlmMetaClient::ServerQuery.new.call(
      jwt_token,
      prompt_execution.llm_uuid,
      prompt_execution.model,
      summarized_context,
      prompt,
      tool_ids: tool_ids,
      generation_settings: generation_settings
    )
  end

  # Build the (summarized_context, prompt) tuple for an LLM call.
  # Shared by both the synchronous and streaming paths.
  def build_streaming_context(prompt_execution, jwt_token, with_tools: false)
    llm_options = LlmMetaClient::ServerResource.available_llm_options(jwt_token)
    raise LlmMetaClient::Exceptions::OllamaUnavailableError, "No LLM available" if llm_options.empty?

    last_msg = ordered_messages.last
    pe = last_msg.prompt_navigator_prompt_execution
    prompt = { role: last_msg.role, prompt: pe.prompt }
    context = pe.build_context(limit: Rails.configuration.summarize_conversation_count)

    summarized_context =
      if context.empty?
        "No context available."
      else
        LlmMetaClient::ServerQuery.new.call(
          jwt_token, prompt_execution.llm_uuid, prompt_execution.model,
          context, "Please summarize the context"
        )
      end
    summarized_context += "Additional prompt: Responses from the assistant must consist solely of the response body."
    if with_tools
      summarized_context += " If a tool call returns an error, do not give up silently — explain the error and what likely caused it (e.g. an invalid argument value)."
    end

    [ summarized_context, prompt ]
  end
end
