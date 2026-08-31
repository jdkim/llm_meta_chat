class ChatsController < ApplicationController
  include ChatManager::ChatManageable
  include ChatManager::CsvDownloadable
  include PromptNavigator::HistoryManageable
  # Allow access without login
  skip_before_action :authenticate_user!, raise: false
  before_action :authenticate_user!, only: [ :update_title, :download_csv, :download_selected_csv, :batch_destroy, :toggle_public ]

  def show
    # Initialize chat context
    initialize_chat visible_chats_scope

    # show is the ONLY action that widens lookup to include admin-flagged
    # public chats — every other action (update_title, add_prompt, destroy,
    # chat_stream, ...) stays owner-gated via visible_chats_scope, so a
    # non-owner viewing a public chat can read the tree but cannot write.
    # .unscope(:order) — visible_chats_scope resolves to `current_user.chats`,
    # a has_many association that carries an implicit order; Rails 8.1's
    # `.or` rejects structurally-incompatible relations, so strip it here.
    @chat = Chat.publicly_viewable.or(visible_chats_scope.unscope(:order)).includes(:messages).find_by!(uuid: params[:id])
    set_active_chat_uuid(@chat&.uuid)
    @messages = @chat.ordered_messages

    # Initialize history
    initialize_history @chat.ordered_prompt_executions

    # Get LLM options available for users
    jwt_token = current_user.jwt_token if user_signed_in?
    @llm_families = LlmMetaClient::ServerResource.available_llm_families(jwt_token)

    # Set active UUID for history sidebar highlighting
    @prompt_execution = @chat.ordered_prompt_executions.last
    set_active_message_uuid(@prompt_execution&.execution_id)

    render "chats/edit"
  rescue StandardError => e
    Rails.logger.error "Error in PromptsController#show: #{e.class} - #{e.message}\n#{e.backtrace&.join("\n")}"
    redirect_to root_path, alert: "Message not found."
  end

  def new
    # Pure new-chat form. No chat row is created until the user actually
    # submits, and nothing is read from session — so opening "/" in a second
    # tab can never surface a previously-active chat from another tab.
    initialize_chat visible_chats_scope
    @chat = nil
    @messages = []
    initialize_history []
    # Admin-curated showcase — visible to anyone landing on `/`. Empty when
    # no chats are flagged, so the view can suppress the section entirely.
    @public_chats = Chat.publicly_viewable.order(created_at: :desc).limit(10)

    jwt_token = current_user.jwt_token if user_signed_in?
    @llm_families = LlmMetaClient::ServerResource.available_llm_families(jwt_token)
  rescue StandardError => e
    Rails.logger.error "Error in ChatsController#new: #{e.class} - #{e.message}\n#{e.backtrace&.join("\n")}"
    @llm_families = []
    flash.now[:alert] = "Chat service is currently unavailable. Please try again later."
  end

  def create
    jwt_token = current_user.jwt_token if user_signed_in?

    # Initialize chat sidebar
    initialize_chat visible_chats_scope

    # Always create a new chat — URL/form is the source of truth for chat
    # identity, not session[:chat_id]. This makes the entry point tab-safe:
    # cross-tab navigation can no longer rewrite the "current chat" under us.
    # Anonymous chats get stamped with the browser session ID so the same
    # visitor can find them in the sidebar across navigation.
    @chat = Chat.create!(user: current_user,
                          session_id: user_signed_in? ? nil : anonymous_session_token)
    add_chat @chat
    set_active_chat_uuid(@chat&.uuid)
    @messages = @chat&.ordered_messages || []

    # initialize history for the chat
    initialize_history @chat&.ordered_prompt_executions

    if params[:message].present?
      # Validate generation settings before proceeding (raises if invalid).
      # The streaming controller re-parses them from the URL.
      begin
        generation_settings_param
      rescue InvalidGenerationSettingsError => e
        @error_message = e.message
        respond_to do |format|
          format.turbo_stream
          format.html { redirect_to new_chat_path, alert: e.message }
        end
        return
      end

      # Add user message (will be rendered via turbo stream)
      @prompt_execution, @user_message = @chat.add_user_message(params[:message],
                                                                params[:api_key_uuid],
                                                                params[:model],
                                                                params[:branch_from_uuid],
                                                                llm_platform: params[:family],
                                                                image: uploaded_image_payload,
                                                                document: uploaded_document_payload)
      # Push to history for rendering
      push_to_history @prompt_execution
      # Set active message UUID for highlighting in UI
      set_active_message_uuid(@prompt_execution&.execution_id || params.dig(:chat, :branch_from_uuid))

      # The assistant response is streamed by ChatStreamsController (SSE).
      # The streaming bubble is rendered by create.turbo_stream.erb and opens
      # the EventSource on connect; persistence + title gen happen at stream close.
      @generation_settings_json = params[:generation_settings_json]
      @tool_ids = Array(params[:tool_ids]).reject(&:blank?)
    end

    # Return turbo stream to render both messages
    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to new_chat_path }
    end
  end

  def destroy
    chat = visible_chats_scope.find_by(uuid: params[:id])
    # "Currently viewing this chat" is now identified by the URL the user
    # came from (referrer), since chat identity is URL-local, not session.
    was_viewed = chat && request.referer.to_s.include?("/chats/#{chat.uuid}")
    chat&.destroy

    initialize_chat visible_chats_scope

    if was_viewed
      redirect_to root_path
    else
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to root_path }
      end
    end
  end

  def batch_destroy
    uuids = Array(params[:uuids]).reject(&:blank?)
    visible_chats_scope.where(uuid: uuids).destroy_all
    redirect_to root_path
  end

  def update_title
    chat = current_user.chats.find_by!(uuid: params[:id])
    title = params[:title].to_s.strip

    if title.blank?
      render json: { error: "Title cannot be blank" }, status: :unprocessable_entity
      return
    end

    title = title.truncate(255)
    chat.update!(title: title)

    render json: {
      title: title,
      truncated_title: title.truncate(30)
    }
  end

  # Admin-curated public showcase. Strict gate: only a super_user AND the
  # chat owner may flip this. visible_chats_scope already narrows to the
  # signed-in user's own chats, so ownership is enforced by the lookup; the
  # explicit super_user? check adds the admin gate on top.
  def toggle_public
    chat = visible_chats_scope.find_by!(uuid: params[:id])
    return head :forbidden unless current_user.super_user?
    chat.update!(public: !chat.public?)
    redirect_to chat_path(chat.uuid),
                notice: chat.public? ? "Chat is now public." : "Chat is no longer public."
  end

  def start_new
    redirect_to root_path
  end

  # Add a prompt to a specific chat identified by URL uuid. This is the
  # tab-safe entry point: chat identity comes from the URL, not session, so
  # navigation in another tab can never re-target the prompt.
  def add_prompt
    jwt_token = current_user.jwt_token if user_signed_in?

    @chat = visible_chats_scope.find_by!(uuid: params[:id])

    initialize_chat visible_chats_scope
    add_chat @chat
    set_active_chat_uuid(@chat&.uuid)
    @messages = @chat&.ordered_messages || []
    initialize_history @chat&.ordered_prompt_executions

    if params[:message].present?
      begin
        generation_settings_param
      rescue InvalidGenerationSettingsError => e
        @error_message = e.message
        respond_to do |format|
          format.turbo_stream { render :create }
          format.html { redirect_to chat_path(@chat.uuid), alert: e.message }
        end
        return
      end

      @prompt_execution, @user_message = @chat.add_user_message(params[:message],
                                                                params[:api_key_uuid],
                                                                params[:model],
                                                                params[:branch_from_uuid],
                                                                llm_platform: params[:family],
                                                                image: uploaded_image_payload,
                                                                document: uploaded_document_payload)
      push_to_history @prompt_execution
      set_active_message_uuid(@prompt_execution&.execution_id || params.dig(:chat, :branch_from_uuid))

      @generation_settings_json = params[:generation_settings_json]
      @tool_ids = Array(params[:tool_ids]).reject(&:blank?)
    end

    @llm_families = LlmMetaClient::ServerResource.available_llm_families(jwt_token) rescue []

    respond_to do |format|
      format.turbo_stream { render :create }
      format.html { redirect_to chat_path(@chat.uuid) }
    end
  rescue ActiveRecord::RecordNotFound
    redirect_to root_path, alert: "Chat not found."
  end

  private

  MAX_IMAGE_BYTES = 8 * 1024 * 1024 # 8 MB
  # 1 MB cap for text documents — they inline directly into the prompt as a
  # fenced code block, so oversized files eat the model's context window.
  MAX_DOCUMENT_BYTES = 1 * 1024 * 1024
  # 10 MB cap for PDFs — they flow as native document blocks (Anthropic/Gemini)
  # rather than inline text, so the constraint is provider-side. Matches the
  # server's Api::ChatStreamsController::MAX_DOCUMENT_BYTES.
  MAX_PDF_BYTES = 10 * 1024 * 1024
  PDF_MIME = "application/pdf"

  class InvalidGenerationSettingsError < StandardError; end

  # Read params[:image] (multipart upload) and return a transport-ready hash
  # `{mime:, data_b64:}` or nil if absent / invalid. Validation is lenient:
  # caller's add_user_message just embeds the data URI; the server enforces
  # vision-model compatibility.
  def uploaded_image_payload
    upload = params[:image]
    return nil if upload.blank? || !upload.respond_to?(:read)
    bytes = upload.read
    return nil if bytes.blank? || bytes.bytesize > MAX_IMAGE_BYTES
    mime = upload.content_type.to_s
    mime = "application/octet-stream" if mime.empty?
    { mime: mime, data_b64: Base64.strict_encode64(bytes) }
  rescue StandardError => e
    Rails.logger.warn "Image upload read failed: #{e.class}: #{e.message}"
    nil
  end

  # Read params[:document] (multipart upload) and return
  # `{mime:, data_b64:, filename:}` or nil. Accepts text-family MIME types
  # (inlined into the prompt) and application/pdf (forwarded as a native
  # multimodal document block to the LLM). Enforces different size caps:
  # 1 MB for text (context-window aware), 10 MB for PDFs (provider-side).
  def uploaded_document_payload
    upload = params[:document]
    return nil if upload.blank? || !upload.respond_to?(:read)
    bytes = upload.read
    return nil if bytes.blank?
    mime = upload.content_type.to_s
    mime = guess_document_mime(upload.original_filename) if mime.empty?
    if mime == PDF_MIME
      return nil if bytes.bytesize > MAX_PDF_BYTES
    elsif mime.start_with?("text/") || %w[application/json application/xml].include?(mime)
      return nil if bytes.bytesize > MAX_DOCUMENT_BYTES
    else
      return nil
    end
    {
      mime: mime,
      data_b64: Base64.strict_encode64(bytes),
      filename: upload.original_filename.to_s.presence || "attachment"
    }
  rescue StandardError => e
    Rails.logger.warn "Document upload read failed: #{e.class}: #{e.message}"
    nil
  end

  def guess_document_mime(filename)
    case File.extname(filename.to_s).downcase
    when ".md"  then "text/markdown"
    when ".csv" then "text/csv"
    when ".txt" then "text/plain"
    when ".json" then "application/json"
    when ".xml"  then "application/xml"
    when ".pdf" then PDF_MIME
    else             "text/plain"
    end
  end

  # Pass-through generation settings: accept any JSON object. Values can be
  # numbers, booleans, strings, or nested hashes (e.g. Ollama's `options`).
  # The provider gem / upstream API decides which keys it understands;
  # unknown keys are typically ignored by the provider.
  def generation_settings_param
    return {} if params[:generation_settings_json].blank?

    parsed = JSON.parse(params[:generation_settings_json])
    raise InvalidGenerationSettingsError, "Generation settings must be a JSON object" unless parsed.is_a?(Hash)

    parsed.deep_symbolize_keys
  rescue JSON::ParserError => e
    raise InvalidGenerationSettingsError, "Invalid JSON: #{e.message}"
  end
end
