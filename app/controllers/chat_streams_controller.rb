class ChatStreamsController < ApplicationController
  include ActionController::Live

  skip_before_action :authenticate_user!, raise: false
  skip_before_action :verify_authenticity_token

  def show
    response.headers["Content-Type"] = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache"
    response.headers["X-Accel-Buffering"] = "no"

    # Initialize early so the disconnect rescue can persist whatever was
    # forwarded before the user clicked Cancel.
    partial = +""
    chat = nil
    prompt_execution = nil
    jwt_token = nil

    chat = find_chat
    prompt_execution = PromptNavigator::PromptExecution.find_by!(execution_id: params[:execution_id])
    unless chat.messages.exists?(prompt_navigator_prompt_execution_id: prompt_execution.id)
      raise ActiveRecord::RecordNotFound
    end

    jwt_token = current_user.id_token if user_signed_in?
    generation_settings = parse_generation_settings(params[:generation_settings_json])
    tool_ids = Array(params[:tool_ids]).reject(&:blank?)

    assembled = chat.stream_assistant_response(prompt_execution, jwt_token, tool_ids: tool_ids, generation_settings: generation_settings) do |event|
      # Accumulate before forwarding so a write failure (ClientDisconnected)
      # doesn't drop the delta we just received.
      partial << event[:data]["delta"].to_s if event[:event] == "message"

      if event[:event] == "tool_calls"
        tool_calls = event[:data]["tool_calls"] || []
        forward(event: "tool_calls", data: {
          tool_calls: tool_calls,
          html: view_context.render(partial: "chats/tool_call_message", locals: { tool_calls: tool_calls })
        })
      else
        forward(event)
      end
    end

    if assembled.present?
      assistant_message = chat.finalize_streamed_response(prompt_execution, assembled, jwt_token)
      if assistant_message
        forward(event: "saved", data: {
          message_id: assistant_message.id,
          execution_id: prompt_execution.execution_id,
          html: view_context.render(partial: "chats/message", locals: { message: assistant_message })
        })
      end

      title_before = chat.title
      chat.generate_title(prompt_execution.prompt, jwt_token)
      if chat.reload.title.present? && chat.title != title_before
        forward(event: "title", data: {
          title: chat.title,
          chat_uuid: chat.uuid,
          turbo_stream: render_sidebar_update(chat)
        })
      end
    end

    forward(event: "done", data: {})
  rescue ActionController::Live::ClientDisconnected
    Rails.logger.info "[ChatStream] client disconnected (partial=#{partial.length} chars)"
    persist_partial(chat, prompt_execution, partial, jwt_token)
  rescue ActiveRecord::RecordNotFound
    forward(event: "error", data: { code: "not_found", message: "Chat or prompt execution not found" }) rescue nil
  rescue StandardError => e
    Rails.logger.error "[ChatStream] #{e.class}: #{e.message}"
    forward(event: "error", data: { code: e.class.name, message: e.message }) rescue nil
  ensure
    response.stream.close
  end

  private

  # Best-effort save of the partial content the user already saw when they
  # cancelled mid-stream. Skips if there's nothing to save or required
  # context wasn't established before the disconnect.
  def persist_partial(chat, prompt_execution, partial, jwt_token)
    return unless chat && prompt_execution && partial.present?
    chat.finalize_streamed_response(prompt_execution, partial, jwt_token)
  rescue StandardError => e
    Rails.logger.warn "[ChatStream] persist_partial failed: #{e.class}: #{e.message}"
  end

  def find_chat
    scope = user_signed_in? ? current_user.chats : Chat.where(user_id: nil)
    scope.find_by!(uuid: params[:chat_id])
  end

  def forward(event)
    name = event[:event]
    payload = event[:data].to_json
    if name.nil? || name == "message"
      response.stream.write "data: #{payload}\n\n"
    else
      response.stream.write "event: #{name}\ndata: #{payload}\n\n"
    end
  end

  def parse_generation_settings(raw)
    return {} if raw.blank?
    parsed = JSON.parse(raw)
    parsed.is_a?(Hash) ? parsed.symbolize_keys : {}
  rescue JSON::ParserError
    {}
  end

  def render_sidebar_update(chat)
    initialize_chat(user_signed_in? ? current_user.chats : nil)
    add_chat(chat)
    view_context.turbo_stream.replace(
      "chat-sidebar",
      partial: "chats/chat_sidebar",
      locals: { chat: chat }
    ).to_s
  end
end
