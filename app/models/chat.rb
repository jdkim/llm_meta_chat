class Chat < ApplicationRecord
  include ChatManager::TitleGeneratable

  belongs_to :user, optional: true
  has_many :messages, dependent: :destroy

  before_create :set_uuid

  # Add a user message to the chat. `image` and `document` are mutually
  # exclusive attachments — the form surface only permits one at a time;
  # if both slip through, image takes precedence.
  def add_user_message(message, llm_uuid, model, branch_from_execution_id = nil, llm_platform: nil, image: nil, document: nil)
    previous_id = if branch_from_execution_id.present?
      PromptNavigator::PromptExecution.find_by(execution_id: branch_from_execution_id)&.id
    else
      messages.where(role: "user").order(:created_at).last&.prompt_navigator_prompt_execution_id
    end
    # Prepend the attachment as a data-URI so the saved prompt round-trips
    # through page reload and the streaming controller (reached over a GET
    # EventSource) can recover it from pe.prompt.
    prompt_with_attachment = if image.present?
      "![](data:#{image[:mime]};base64,#{image[:data_b64]})\n\n#{message}"
    elsif document.present?
      "[#{document[:filename]}](data:#{document[:mime]};base64,#{document[:data_b64]})\n\n#{message}"
    else
      message
    end
    prompt_execution = PromptNavigator::PromptExecution.create!(
      prompt: prompt_with_attachment,
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
  # Cap on historical images carried into each subsequent turn alongside the
  # current image. Bigger numbers grow per-request image-token cost linearly;
  # 2 is enough for "compare with the one I just sent" without runaway cost.
  HISTORICAL_IMAGE_LIMIT = 2

  def stream_assistant_response(prompt_execution, jwt_token, tool_ids: [], generation_settings: {}, &block)
    # Anchor on the explicit `prompt_execution` (the user's just-added PE),
    # not `ordered_messages.last`. They coincide in a linear chat, but the
    # explicit PE is what carries the correct `previous` chain when the user
    # branched from an older point in the history pane — context and
    # historical images must follow that chain, not the chat's global
    # chronological order.
    pe = prompt_execution
    text_prompt, attached_image = extract_attached_image(pe.prompt)
    text_prompt, attached_document = extract_attached_document(text_prompt)
    # PDFs travel to the LLM as native multimodal document blocks via the
    # server's `document:` param — the server picks the provider dispatch
    # (Anthropic document block, Gemini inline_data). Text docs stay in the
    # prompt as a fenced code block so any provider handles them uniformly.
    pdf_document = pdf_document?(attached_document) ? attached_document : nil
    text_prompt = inline_document_content(attached_document, text_prompt) if attached_document && pdf_document.nil?
    prompt = { role: "user", prompt: text_prompt }
    images_payload = collect_recent_images(pe, current_image: attached_image)

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
        images: images_payload.presence,
        document: pdf_document&.slice(:mime, :data_b64),
        &block
      )
    end
  end

  # Walks the lineage backwards from `pe.previous`, harvests the most recent
  # `HISTORICAL_IMAGE_LIMIT` images, then appends `current_image`. Result is
  # ordered chronologically (oldest first); current turn's image is the last
  # element. Returns [] when no images are involved.
  def collect_recent_images(pe, current_image:)
    historical = []
    cursor = pe.previous
    while cursor && historical.size < HISTORICAL_IMAGE_LIMIT
      _text, img = extract_attached_image(cursor.prompt)
      historical.unshift(img) if img
      cursor = cursor.previous
    end
    historical + (current_image ? [ current_image ] : [])
  end

  # Persist the streamed assistant response. Skips persistence if content is blank
  # or if this PromptExecution already has an assistant Message — idempotency
  # guard so a mid-flight ClientDisconnected during post-stream work (e.g.
  # title generation) doesn't cause the ChatStreamsController's rescue path to
  # persist a second row for a stream that already completed.
  def finalize_streamed_response(prompt_execution, content, jwt_token)
    return nil if content.blank?

    existing = messages.find_by(role: "assistant", prompt_navigator_prompt_execution_id: prompt_execution.id)
    return existing if existing

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

  def ordered_prompt_executions
    messages
      .where(role: "user")
      .includes(:prompt_navigator_prompt_execution)
      .order(:created_at)
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
    # Strip any attached data-URI image or document from the prompt before
    # titling; the summarizer shouldn't see the raw attachment markdown.
    text_only, _image = extract_attached_image(prompt_text)
    text_only, _doc   = extract_attached_document(text_only)
    return nil if text_only.blank?

    # Fallback used whenever LLM summarization produces no usable title
    # (model emitted only reasoning sentinels, returned blank, request
    # failed, etc.). Without a fallback the chat is hidden from the
    # sidebar entirely because chat_manager filters on title.present?.
    fallback_title = text_only.truncate(50)

    latest_pe = ordered_prompt_executions.last
    return fallback_title unless latest_pe&.llm_uuid && latest_pe&.model

    raw = LlmMetaClient::ServerQuery.new.call(
      jwt_token,
      latest_pe.llm_uuid,
      latest_pe.model,
      "No context available.",
      { role: "user", prompt: "Please summarize the following text into a short title (max 50 characters). Respond with only the title, nothing else: #{text_only}" }
    )
    strip_title_markdown(raw).presence || fallback_title
  rescue StandardError => e
    Rails.logger.warn "[Chat#summarize_for_title] LLM call failed, falling back to prompt: #{e.class}: #{e.message}"
    text_only.truncate(50)
  end

  # LLMs frequently wrap titles in markdown emphasis (**bold**, *italic*),
  # backtick-code, leading "# heading" marks, or surrounding quotes —
  # sometimes despite explicit instructions to return plain text. Strip
  # those artifacts so the chat sidebar shows a clean title.
  def strip_title_markdown(text)
    text.to_s
        .gsub(/<unused94>.*?<unused95>/m, "")             # Gemma reasoning block
        .gsub(/<unused\d+>/, "")                          # orphaned Gemma sentinels
        .gsub(/\A\s*#+\s*/, "")                          # leading "# "
        .gsub(/`([^`]+)`/, '\1')                          # `inline code`
        .gsub(/\*\*\*([^\*]+)\*\*\*/, '\1')               # ***triple***
        .gsub(/\*\*([^\*]+)\*\*/, '\1')                   # **bold**
        .gsub(/\*([^\*]+)\*/, '\1')                       # *italic*
        .gsub(/__([^_]+)__/, '\1')                        # __bold__
        .gsub(/_([^_]+)_/, '\1')                          # _italic_
        .gsub(/\A["'“”‘’「『]+|["'“”‘’」』]+\z/, "")  # wrapping quotes
        .strip
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
  # Shared by both the synchronous and streaming paths. Anchors on the
  # explicit `prompt_execution` so branched chats (new prompt sent from an
  # older selected history pane entry) walk the correct lineage.
  def build_streaming_context(prompt_execution, jwt_token, with_tools: false)
    llm_options = LlmMetaClient::ServerResource.available_llm_options(jwt_token)
    raise LlmMetaClient::Exceptions::OllamaUnavailableError, "No LLM available" if llm_options.empty?

    pe = prompt_execution
    # Use the image-stripped prompt text. The actual image bytes flow as a
    # structured `images:` field on the streaming path; embedding the data
    # URI here would re-send the same image as ~30k useless text tokens.
    current_text, _img = extract_attached_image(pe.prompt)
    current_text, attached_document = extract_attached_document(current_text)
    # PDFs travel as a native document block via the client's `document:` param,
    # so don't inline the binary blob here. Text docs still get inlined.
    if attached_document && !pdf_document?(attached_document)
      current_text = inline_document_content(attached_document, current_text)
    end
    prompt = { role: "user", prompt: current_text }

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
        older = context[0...-verbatim_count].map { |t| strip_inline_images_in_turn(t) }
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
    turns.map { |t|
      stripped = strip_inline_images_in_turn(t)
      "User: #{stripped[:prompt]}\nAssistant: #{stripped[:response]}"
    }.join("\n\n")
  end

  # Replace embedded data-URI attachments with short placeholders in a
  # turn-hash. Both image (`![](data:…)`) and document (`[filename](data:…)`)
  # data URIs get stripped — the actual bytes are sent separately (images via
  # the `images:` field; documents get inlined into the current turn's text).
  # Leaving the data URI in prior turns would re-send each attachment as
  # tens of thousands of useless tokens per subsequent turn.
  INLINE_DATA_IMAGE    = /!\[[^\]]*\]\(data:[^)]+\)/m
  INLINE_DATA_DOCUMENT = /(?<!!)\[([^\]]*)\]\(data:[^)]+\)/m
  def strip_inline_images_in_turn(turn)
    {
      prompt:   strip_inline_attachments(turn[:prompt]),
      response: strip_inline_attachments(turn[:response])
    }
  end

  def strip_inline_attachments(text)
    text.to_s
        .gsub(INLINE_DATA_IMAGE, "[image]")
        .gsub(INLINE_DATA_DOCUMENT) { "[document: #{Regexp.last_match(1)}]" }
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

  # Pull a single leading `[filename](data:mime;base64,DATA)` document out of the
  # prompt text. Distinct from ATTACHED_IMAGE_HEAD by the absence of the leading `!`.
  # Returns [text_without_doc, {mime:, data_b64:, filename:}|nil].
  ATTACHED_DOCUMENT_HEAD = /\A\[([^\]]*)\]\(data:([^;]+);base64,([^\)]+)\)\s*\n*/m
  def extract_attached_document(prompt_text)
    m = prompt_text.to_s.match(ATTACHED_DOCUMENT_HEAD)
    return [ prompt_text.to_s, nil ] unless m
    stripped = prompt_text.sub(ATTACHED_DOCUMENT_HEAD, "")
    [ stripped, { filename: m[1], mime: m[2], data_b64: m[3] } ]
  end

  # PDF attachments travel as native multimodal document blocks to the
  # provider (via the client's `document:` kwarg → server → llm.rb's
  # `LLM::File` pipeline), NOT inlined as text. Every other document mime
  # gets decoded and inlined as a fenced code block.
  def pdf_document?(document)
    document && document[:mime].to_s == "application/pdf"
  end

  # Decode a text-document attachment and inline its content into the prompt
  # as a fenced code block, so the LLM sees the file contents as context.
  # Language hint derived from the filename extension (falls back to "text").
  def inline_document_content(document, user_text)
    content = Base64.decode64(document[:data_b64].to_s).force_encoding("UTF-8")
    return user_text unless content.valid_encoding?
    lang = File.extname(document[:filename].to_s).delete(".").downcase
    lang = "text" if lang.empty? || !lang.match?(/\A[a-z0-9]+\z/)
    "Attached: #{document[:filename]}\n```#{lang}\n#{content}\n```\n\n#{user_text}"
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
