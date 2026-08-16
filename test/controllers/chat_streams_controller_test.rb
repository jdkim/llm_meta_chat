require "test_helper"

# Guards the §2.2 paper claim: "any partial content received before
# cancellation is persisted." The unit behavior of
# Chat#finalize_streamed_response is already covered in chat_test.rb; this
# file guards the wiring from the SSE endpoint's ClientDisconnected rescue
# through persist_partial into that method.
class ChatStreamsControllerTest < ActionDispatch::IntegrationTest
  teardown do
    restore_chat_stream_assistant_response!
  end

  test "persists partial content when the client disconnects mid-stream (§2.2 guard)" do
    setup_pending_assistant_turn
    stub_stream_assistant_response_with_disconnect!(deltas: [ "Hello, ", "world" ])

    assert_difference -> { @chat.messages.where(role: "assistant").count }, 1 do
      get chat_stream_path(@chat.uuid), params: { execution_id: @pe.execution_id },
          headers: { "User-Agent" => modern_browser_ua }
    end

    saved = @chat.messages.find_by(role: "assistant", prompt_navigator_prompt_execution_id: @pe.id)
    assert_not_nil saved, "assistant Message should be persisted when the client cancels mid-stream"
    assert_equal "Hello, world", @pe.reload.response
  end

  test "persists nothing when the client disconnects before any delta arrives" do
    setup_pending_assistant_turn
    stub_stream_assistant_response_with_disconnect!(deltas: [])

    assert_no_difference -> { @chat.messages.where(role: "assistant").count } do
      get chat_stream_path(@chat.uuid), params: { execution_id: @pe.execution_id },
          headers: { "User-Agent" => modern_browser_ua }
    end
    assert_nil @pe.reload.response
  end

  private

  # ApplicationController has `allow_browser versions: :modern`, which
  # rejects requests without a recognised modern-browser User-Agent —
  # including the default Rails test UA. Every request in this file needs
  # to spoof one.
  def modern_browser_ua
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
  end

  # Drive a POST /chats to create an anonymous chat + user Message + PE
  # stamped with the test session's anon_chat_token, so visible_chats_scope
  # in the streaming controller resolves the chat correctly for GET /stream.
  def setup_pending_assistant_turn
    with_stub(LlmMetaClient::ServerResource, :available_llm_families, []) do
      post chats_path, params: {
        message: "what is the capital of France?",
        api_key_uuid: "ollama-local", model: "llama3.2", family: "ollama"
      }, headers: { "User-Agent" => modern_browser_ua }
    end
    @chat = Chat.where(user_id: nil).order(:id).last
    @pe = @chat.messages.order(:id).first.prompt_navigator_prompt_execution
  end

  # Swap Chat#stream_assistant_response for one that yields the given deltas
  # as SSE message events and then raises ClientDisconnected — the same
  # exception ActionController::Live raises when the browser closes its
  # EventSource. teardown restores the original.
  def stub_stream_assistant_response_with_disconnect!(deltas:)
    events = deltas.map { |d| { event: "message", data: { "delta" => d } } }
    Chat.class_eval do
      alias_method :__orig_stream_assistant_response, :stream_assistant_response unless method_defined?(:__orig_stream_assistant_response)
    end
    Chat.class_eval do
      define_method(:stream_assistant_response) do |*_, **__, &block|
        events.each { |ev| block&.call(ev) }
        raise ActionController::Live::ClientDisconnected
      end
    end
  end

  def restore_chat_stream_assistant_response!
    return unless Chat.method_defined?(:__orig_stream_assistant_response)
    Chat.class_eval do
      alias_method :stream_assistant_response, :__orig_stream_assistant_response
      remove_method :__orig_stream_assistant_response
    end
  end
end
