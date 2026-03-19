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

    @chat = current_user&.chats.includes(:messages).find_by(uuid: params[:id])
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
      current_user,
      llm_uuid: params[:api_key_uuid],
      model: params[:model]
    )
    add_chat @chat
    @messages = @chat&.ordered_messages || []

    # initialize history for the chat
    initialize_history @chat&.ordered_by_descending_prompt_executions

    if params[:message].present?
      # Add user message (will be rendered via turbo stream)
      @prompt_execution, @user_message = @chat.add_user_message(params[:message],
                                                                params[:model],
                                                                params[:branch_from_uuid])
      # Push to history for rendering
      push_to_history @prompt_execution
      # Set active message UUID for highlighting in UI
      set_active_message_uuid(@prompt_execution&.execution_id || params.dig(:chat, :branch_from_uuid))

      # Send to LLM and get assistant response
      begin
        @assistant_message = @chat.add_assistant_response(@prompt_execution, jwt_token, tool_ids: tool_ids_param, generation_settings: generation_settings_param)
        # Generate chat title from the user's prompt (only if title is not yet set)
        @chat.generate_title(params[:message], jwt_token)
      rescue StandardError => e
        Rails.logger.error "Error in chat response: #{e.class} - #{e.message}\n#{e.backtrace&.join("\n")}"
        @error_message = "An error occurred while getting the response. Please try again."
      end
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
      current_user,
      llm_uuid: params[:api_key_uuid],
      model: params[:model]
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

    # Find or create chat
    @chat = Chat.find_or_switch_for_session(
      session,
      current_user,
      llm_uuid: params[:api_key_uuid],
      model: params[:model]
    )
    @messages = @chat&.ordered_messages || []
    # initialize history for the chat
    initialize_history @chat&.ordered_by_descending_prompt_executions

    if params[:message].present?
      # Add user message (will be rendered via turbo stream)
      @prompt_execution, @user_message = @chat.add_user_message(params[:message],
                                                               params[:model],
                                                               params[:branch_from_uuid])
      # Push to history for rendering
      push_to_history @prompt_execution
      # Set active message UUID for highlighting in UI
      set_active_message_uuid(@prompt_execution&.execution_id || params.dig(:chat, :branch_from_uuid))

      # Send to LLM and get assistant response
      begin
        @assistant_message = @chat.add_assistant_response(@prompt_execution, jwt_token, tool_ids: tool_ids_param, generation_settings: generation_settings_param)
      rescue StandardError => e
        Rails.logger.error "Error in chat response: #{e.class} - #{e.message}\n#{e.backtrace&.join("\n")}"
        @error_message = "An error occurred while getting the response. Please try again."
      end
    end

    # Return turbo stream to render both messages
    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to new_chat_path }
    end
  end

  private

  def tool_ids_param
    params[:tool_ids].presence || []
  end

  def generation_settings_param
    settings = {}
    settings[:temperature] = params[:temperature].to_f if params[:temperature].present?
    settings[:top_k] = params[:top_k].to_i if params[:top_k].present?
    settings[:top_p] = params[:top_p].to_f if params[:top_p].present?
    settings[:max_tokens] = params[:max_tokens].to_i if params[:max_tokens].present?
    settings[:repeat_penalty] = params[:repeat_penalty].to_f if params[:repeat_penalty].present?
    settings
  end
end
