class ChatsController < ApplicationController
  include ChatManager::ChatManageable
  include ChatManager::CsvDownloadable
  include PromptNavigator::HistoryManageable
  # Allow access without login
  skip_before_action :authenticate_user!, raise: false
  before_action :authenticate_user!, only: [ :update_title, :download_csv, :download_selected_csv, :batch_destroy ]

  def show
    # Initialize chat context
    initialize_chat current_user&.chats

    @chat = current_user&.chats.includes(:messages).find_by!(uuid: params[:id])
    set_active_chat_uuid(@chat&.uuid)
    @messages = @chat.ordered_messages

    # Initialize history
    initialize_history @chat.ordered_by_descending_prompt_executions

    # Get LLM options available for users
    jwt_token = current_user.id_token if user_signed_in?
    @llm_families = LlmMetaClient::ServerResource.available_llm_families(jwt_token)

    # Set active UUID for history sidebar highlighting
    @prompt_execution = @chat.ordered_by_descending_prompt_executions.first
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
    initialize_chat current_user&.chats
    @chat = nil
    @messages = []
    initialize_history []

    jwt_token = current_user.id_token if user_signed_in?
    @llm_families = LlmMetaClient::ServerResource.available_llm_families(jwt_token)
  rescue StandardError => e
    Rails.logger.error "Error in ChatsController#new: #{e.class} - #{e.message}\n#{e.backtrace&.join("\n")}"
    @llm_families = []
    flash.now[:alert] = "Chat service is currently unavailable. Please try again later."
  end

  def create
    jwt_token = current_user.id_token if user_signed_in?

    # Initialize chat sidebar
    initialize_chat current_user&.chats

    # Always create a new chat — URL/form is the source of truth for chat
    # identity, not session[:chat_id]. This makes the entry point tab-safe:
    # cross-tab navigation can no longer rewrite the "current chat" under us.
    @chat = Chat.create!(user: current_user)
    add_chat @chat
    set_active_chat_uuid(@chat&.uuid)
    @messages = @chat&.ordered_messages || []

    # initialize history for the chat
    initialize_history @chat&.ordered_by_descending_prompt_executions

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
                                                                image: uploaded_image_payload)
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
    scope = user_signed_in? ? current_user.chats : Chat.where(user_id: nil)
    chat = scope.find_by(uuid: params[:id])
    # "Currently viewing this chat" is now identified by the URL the user
    # came from (referrer), since chat identity is URL-local, not session.
    was_viewed = chat && request.referer.to_s.include?("/chats/#{chat.uuid}")
    chat&.destroy

    initialize_chat(user_signed_in? ? current_user.chats : nil)

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
    scope = user_signed_in? ? current_user.chats : Chat.where(user_id: nil)
    uuids = Array(params[:uuids]).reject(&:blank?)
    scope.where(uuid: uuids).destroy_all
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

  def start_new
    redirect_to root_path
  end

  # Add a prompt to a specific chat identified by URL uuid. This is the
  # tab-safe entry point: chat identity comes from the URL, not session, so
  # navigation in another tab can never re-target the prompt.
  def add_prompt
    jwt_token = current_user.id_token if user_signed_in?

    scope = user_signed_in? ? current_user.chats : Chat.where(user_id: nil)
    @chat = scope.find_by!(uuid: params[:id])

    initialize_chat current_user&.chats
    add_chat @chat
    set_active_chat_uuid(@chat&.uuid)
    @messages = @chat&.ordered_messages || []
    initialize_history @chat&.ordered_by_descending_prompt_executions

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
                                                                image: uploaded_image_payload)
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

  ALLOWED_GENERATION_KEYS = %w[temperature top_k top_p max_tokens repeat_penalty].freeze
  MAX_IMAGE_BYTES = 8 * 1024 * 1024 # 8 MB

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

  def generation_settings_param
    return {} if params[:generation_settings_json].blank?

    parsed = JSON.parse(params[:generation_settings_json])
    raise InvalidGenerationSettingsError, "Generation settings must be a JSON object" unless parsed.is_a?(Hash)

    settings = parsed.slice(*ALLOWED_GENERATION_KEYS)
    invalid_keys = parsed.keys - ALLOWED_GENERATION_KEYS
    raise InvalidGenerationSettingsError, "Unknown keys: #{invalid_keys.join(', ')}" if invalid_keys.any?

    non_numeric = settings.reject { |_k, v| v.is_a?(Numeric) }
    if non_numeric.any?
      raise InvalidGenerationSettingsError, "Values must be numeric: #{non_numeric.keys.join(', ')}"
    end

    settings.symbolize_keys
  rescue JSON::ParserError => e
    raise InvalidGenerationSettingsError, "Invalid JSON: #{e.message}"
  end
end
