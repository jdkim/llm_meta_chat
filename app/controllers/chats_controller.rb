class ChatsController < ApplicationController
  include ChatManager::ChatManageable
  include ChatManager::CsvDownloadable
  include PromptNavigator::HistoryManageable
  # Allow access without login
  skip_before_action :authenticate_user!, raise: false
  before_action :authenticate_user!, only: [ :update_title, :download_csv, :download_all_csv ]

  def show
    # Initialize chat context
    initialize_chat current_user&.chats

    @chat = current_user&.chats.includes(:messages).find_by!(uuid: params[:id])
    session[:chat_id] = @chat.id
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
    initialize_chat current_user&.chats
    # Find current conversation or create it on create method if not found
    @chat = Chat.find_or_switch_for_session(
      session,
      current_user
    )
    add_chat @chat
    @messages = @chat&.ordered_messages || []
    # initialize history for the chat
    initialize_history @chat&.ordered_by_descending_prompt_executions

    # Get LLM options available for users
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

    # Find or create chat
    @chat = Chat.find_or_switch_for_session(
      session,
      current_user
    )
    add_chat @chat
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
                                                                params[:branch_from_uuid])
      # Push to history for rendering
      push_to_history @prompt_execution
      # Set active message UUID for highlighting in UI
      set_active_message_uuid(@prompt_execution&.execution_id || params.dig(:chat, :branch_from_uuid))

      # The assistant response is streamed by ChatStreamsController (SSE).
      # The streaming bubble is rendered by create.turbo_stream.erb and opens
      # the EventSource on connect; persistence + title gen happen at stream close.
      @generation_settings_json = params[:generation_settings_json]
    end

    # Return turbo stream to render both messages
    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to new_chat_path }
    end
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
    session.delete(:chat_id)
    redirect_to root_path
  end

  def edit
    # Initialize chat context
    initialize_chat current_user&.chats

    # Get LLM options available for users
    jwt_token = current_user.id_token if user_signed_in?
    @llm_families = LlmMetaClient::ServerResource.available_llm_families(jwt_token)

    @chat = Chat.find_or_switch_for_session(
      session,
      current_user
    )
    @messages = @chat&.ordered_messages || []
    # initialize history for the chat
    initialize_history @chat&.ordered_by_descending_prompt_executions
    # Set active message UUID for highlighting in UI
    set_active_message_uuid(params.dig(:chat, :branch_from_uuid))
  rescue StandardError => e
    Rails.logger.error "Error in ChatsController#edit: #{e.class} - #{e.message}\n#{e.backtrace&.join("\n")}"
    @llm_families = []
    flash.now[:alert] = "Chat service is currently unavailable. Please try again later."
  end

  def update
    jwt_token = current_user.id_token if user_signed_in?

    # Use the chat identified by the URL, not the session
    @chat = current_user.chats.find(params[:id])
    session[:chat_id] = @chat.id
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
          format.html { redirect_to chat_path(@chat), alert: e.message }
        end
        return
      end

      # Add user message (will be rendered via turbo stream)
      @prompt_execution, @user_message = @chat.add_user_message(params[:message],
                                                               params[:api_key_uuid],
                                                               params[:model],
                                                               params[:branch_from_uuid])
      # Push to history for rendering
      push_to_history @prompt_execution
      # Set active message UUID for highlighting in UI
      set_active_message_uuid(@prompt_execution&.execution_id || params.dig(:chat, :branch_from_uuid))

      # The assistant response is streamed by ChatStreamsController (SSE).
      # See create action for details.
      @generation_settings_json = params[:generation_settings_json]
    end

    # Return turbo stream to render both messages
    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to new_chat_path }
    end
  end

  private

  ALLOWED_GENERATION_KEYS = %w[temperature top_k top_p max_tokens repeat_penalty].freeze

  class InvalidGenerationSettingsError < StandardError; end

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
