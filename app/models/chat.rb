class Chat < ApplicationRecord
  include ChatManager::TitleGeneratable

  belongs_to :user, optional: true
  has_many :messages, dependent: :destroy

  before_create :set_uuid

  # Add a user message to the chat
  def add_user_message(message, llm_uuid, model, branch_from_execution_id = nil, llm_platform: nil, image: nil)
    previous_id = if branch_from_execution_id.present?
      PromptNavigator::PromptExecution.find_by(execution_id: branch_from_execution_id)&.id
    else
      messages.where(role: "user").order(:created_at).last&.prompt_navigator_prompt_execution_id
    end
    # Prepend the attached image as a data-URI markdown image so the saved
    # prompt renders the image on reload, and so the streaming controller
    # (reached over a GET EventSource) can recover the image from pe.prompt.
    prompt_with_image = image.present? ? "![](data:#{image[:mime]};base64,#{image[:data_b64]})\n\n#{message}" : message
    prompt_execution = PromptNavigator::PromptExecution.create!(
      prompt: prompt_with_image,
      llm_uuid: llm_uuid,
      model: model,
      llm_platform: llm_platform,
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
    last_msg = ordered_messages.last
    pe = last_msg.prompt_navigator_prompt_execution
    # Separate any attached image (data-URI markdown at the head of the
    # prompt) from the text. The image flows as a structured field; the text
    # goes through the usual prompt path.
    text_prompt, attached_image = extract_attached_image(pe.prompt)
    prompt = { role: last_msg.role, prompt: text_prompt }

    if image_model?(prompt_execution.model)
      image_context = pe.build_context(limit: Rails.configuration.summarize_conversation_count)
      LlmMetaClient::ServerQuery.new.stream(
        jwt_token,
        prompt_execution.llm_uuid,
        prompt_execution.model,
        "",
        prompt,
        generation_settings: generation_settings,
        image_context: image_context,
        image: attached_image,
        &block
      )
    else
      summarized_context, prompt = build_streaming_context(prompt_execution, jwt_token, with_tools: tool_ids.any?)
      LlmMetaClient::ServerQuery.new.stream(
        jwt_token,
        prompt_execution.llm_uuid,
        prompt_execution.model,
        summarized_context,
        prompt,
        tool_ids: tool_ids,
        generation_settings: generation_settings,
        image: attached_image,
        &block
      )
    end
  end

  # Persist the streamed assistant response. Skips persistence if content is blank.
  def finalize_streamed_response(prompt_execution, content, jwt_token)
    return nil if content.blank?

    prompt_execution.update!(
      llm_platform: prompt_execution.llm_platform.presence || resolve_llm_type(prompt_execution.llm_uuid, jwt_token),
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
    # Strip any attached data-URI image from the prompt before titling; the
    # summarizer shouldn't see the image markdown (it leads to titles like
    # "Undefined Image" derived from the empty alt text).
    text_only, _image = extract_attached_image(prompt_text)
    return nil if text_only.blank?

    latest_pe = ordered_by_descending_prompt_executions.first
    return nil unless latest_pe&.llm_uuid && latest_pe&.model

    LlmMetaClient::ServerQuery.new.call(
      jwt_token,
      latest_pe.llm_uuid,
      latest_pe.model,
      "No context available.",
      { role: "user", prompt: "Please summarize the following text into a short title (max 50 characters). Respond with only the title, nothing else: #{text_only}" }
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

    # Image-generation models don't take prior context. Summarizing through
    # an image model would just generate an image as the "summary".
    if image_model?(prompt_execution.model)
      return [ "No context available.", prompt ]
    end

    verbatim_count = Rails.configuration.summarize_conversation_count
    context = pe.build_context(limit: verbatim_count * 4)

    summarized_context =
      if context.empty?
        "No context available."
      elsif context.size <= verbatim_count
        # Within budget: replay recent turns verbatim, no summarization call.
        format_transcript(context)
      else
        # Overflow: summarize the older slice, keep recent turns verbatim.
        # Summarization runs on a cheap fixed model, not the user's selected
        # one. Falls back to the user's model if it isn't available.
        older = context[0...-verbatim_count]
        recent = context.last(verbatim_count)
        sum_uuid, sum_model =
          summarization_target(llm_options) || [ prompt_execution.llm_uuid, prompt_execution.model ]
        summary = LlmMetaClient::ServerQuery.new.call(
          jwt_token, sum_uuid, sum_model,
          older, "Please summarize the context"
        )
        "Summary of earlier conversation: #{summary}\n\nRecent conversation:\n#{format_transcript(recent)}"
      end
    summarized_context += "Additional prompt: Responses from the assistant must consist solely of the response body."
    if with_tools
      summarized_context += " If a tool call returns an error, do not give up silently — explain the error and what likely caused it (e.g. an invalid argument value)."
    end

    [ summarized_context, prompt ]
  end

  def image_model?(model_meta_id)
    model_meta_id.to_s.include?("image")
  end

  def format_transcript(turns)
    turns.map { |t| "User: #{t[:prompt]}\nAssistant: #{t[:response]}" }.join("\n\n")
  end

  # Pull a single leading `![](data:mime;base64,DATA)` image out of the prompt
  # text. Returns [text_without_image, {mime:, data_b64:}|nil]. v1 supports a
  # single image per turn.
  ATTACHED_IMAGE_HEAD = /\A!\[[^\]]*\]\(data:([^;]+);base64,([^\)]+)\)\s*\n*/m
  def extract_attached_image(prompt_text)
    m = prompt_text.to_s.match(ATTACHED_IMAGE_HEAD)
    return [ prompt_text.to_s, nil ] unless m
    stripped = prompt_text.sub(ATTACHED_IMAGE_HEAD, "")
    [ stripped, { mime: m[1], data_b64: m[2] } ]
  end

  # Cheap model used to condense overflow context. Configured via
  # Rails.configuration.summarization_model (env LLM_SUMMARIZATION_MODEL
  # or credentials[:llm_service][:summarization_model]). If the configured
  # meta_id isn't in the ollama family's catalog at request time, the
  # caller falls back to the user's selected model.
  def summarization_target(llm_options)
    ollama = llm_options.find { |o| o[:llm_type] == "ollama" }
    return nil unless ollama

    target = Rails.configuration.summarization_model
    return nil unless target.present?

    models = ollama[:available_models] || []
    available = models.any? { |m| (m["value"] || m[:value]) == target }
    return nil unless available

    [ ollama[:uuid], target ]
  end
end
