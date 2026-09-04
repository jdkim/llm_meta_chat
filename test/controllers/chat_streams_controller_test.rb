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

  # Reasoning used to live only in the DOM of the tab that streamed it, so it
  # vanished on reload. These guard the wiring that stores it on the message.
  test "persists streamed reasoning alongside the response" do
    setup_pending_assistant_turn
    stub_stream_assistant_response!(events: [
      { event: "thinking", data: { "delta" => "First I check " } },
      { event: "thinking", data: { "delta" => "the constraints." } },
      { event: "message",  data: { "delta" => "Paris." } }
    ], assembled: "Paris.")

    get chat_stream_path(@chat.uuid), params: { execution_id: @pe.execution_id },
        headers: { "User-Agent" => modern_browser_ua }

    saved = @chat.messages.find_by(role: "assistant", prompt_navigator_prompt_execution_id: @pe.id)
    assert_not_nil saved
    assert_equal "First I check the constraints.", saved.reasoning
    assert_equal "Paris.", @pe.reload.response
  end

  test "renders the persisted Reasoning block in the saved message html" do
    setup_pending_assistant_turn
    stub_stream_assistant_response!(events: [
      { event: "thinking", data: { "delta" => "Weighing the options." } },
      { event: "message",  data: { "delta" => "Paris." } }
    ], assembled: "Paris.")

    get chat_stream_path(@chat.uuid), params: { execution_id: @pe.execution_id },
        headers: { "User-Agent" => modern_browser_ua }

    # The `saved` event carries the rendered partial the client swaps in, so
    # the persisted block reaches the page without a reload.
    assert_includes response.body, "message-thinking"
    assert_includes response.body, "Reasoning"
    assert_includes response.body, "Weighing the options."
  end

  # The controller must still FORWARD thinking events to the browser, not just
  # accumulate them — otherwise the live streaming block never appears.
  test "still forwards thinking events to the client while accumulating them" do
    setup_pending_assistant_turn
    stub_stream_assistant_response!(events: [
      { event: "thinking", data: { "delta" => "live-delta" } },
      { event: "message",  data: { "delta" => "Paris." } }
    ], assembled: "Paris.")

    get chat_stream_path(@chat.uuid), params: { execution_id: @pe.execution_id },
        headers: { "User-Agent" => modern_browser_ua }

    assert_includes response.body, "event: thinking"
    assert_match(/event: thinking\ndata: .*live-delta/, response.body)
  end

  test "stores no reasoning when the model emitted none" do
    setup_pending_assistant_turn
    stub_stream_assistant_response!(events: [
      { event: "message", data: { "delta" => "Paris." } }
    ], assembled: "Paris.")

    get chat_stream_path(@chat.uuid), params: { execution_id: @pe.execution_id },
        headers: { "User-Agent" => modern_browser_ua }

    saved = @chat.messages.find_by(role: "assistant", prompt_navigator_prompt_execution_id: @pe.id)
    assert_nil saved.reasoning
    assert_not_includes response.body, "message-thinking"
  end

  test "keeps reasoning received before a mid-stream cancel" do
    setup_pending_assistant_turn
    stub_stream_assistant_response_with_disconnect!(
      deltas: [ "Hello, ", "world" ],
      thinking: [ "Half a thought" ]
    )

    get chat_stream_path(@chat.uuid), params: { execution_id: @pe.execution_id },
        headers: { "User-Agent" => modern_browser_ua }

    saved = @chat.messages.find_by(role: "assistant", prompt_navigator_prompt_execution_id: @pe.id)
    assert_equal "Half a thought", saved.reasoning
    assert_equal "Hello, world", @pe.reload.response
  end

  # A turn that fails late (the hub's turn budget stopping a slow local model
  # is the usual case) has often produced a real answer and a lot of reasoning
  # already. Discarding it loses work the user watched stream.
  test "persists partial content and reasoning when the turn errors" do
    setup_pending_assistant_turn
    stub_stream_assistant_response_with_error!(
      deltas: [ "The moving ", "time is 2h29m." ],
      thinking: [ "14:20 to 17:05 is 2h45m, ", "minus two 8-minute stops." ],
      error: LlmMetaClient::Exceptions::ServerError.new("still generating after 300 seconds")
    )

    assert_difference -> { @chat.messages.where(role: "assistant").count }, 1 do
      get chat_stream_path(@chat.uuid), params: { execution_id: @pe.execution_id },
          headers: { "User-Agent" => modern_browser_ua }
    end

    saved = @chat.messages.find_by(role: "assistant", prompt_navigator_prompt_execution_id: @pe.id)
    assert_equal "The moving time is 2h29m.", @pe.reload.response
    assert_equal "14:20 to 17:05 is 2h45m, minus two 8-minute stops.", saved.reasoning
    # The client is still told the turn failed.
    assert_includes response.body, "event: error"
  end

  test "persists nothing when the turn errors before any delta" do
    setup_pending_assistant_turn
    stub_stream_assistant_response_with_error!(
      deltas: [], thinking: [],
      error: LlmMetaClient::Exceptions::ServerError.new("upstream refused")
    )

    assert_no_difference -> { @chat.messages.where(role: "assistant").count } do
      get chat_stream_path(@chat.uuid), params: { execution_id: @pe.execution_id },
          headers: { "User-Agent" => modern_browser_ua }
    end
    assert_includes response.body, "event: error"
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
  def stub_stream_assistant_response_with_disconnect!(deltas:, thinking: [])
    events = thinking.map { |t| { event: "thinking", data: { "delta" => t } } } +
             deltas.map { |d| { event: "message", data: { "delta" => d } } }
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

  def stub_stream_assistant_response!(events:, assembled:)
    Chat.class_eval do
      alias_method :__orig_stream_assistant_response, :stream_assistant_response unless method_defined?(:__orig_stream_assistant_response)
      alias_method :__orig_generate_title, :generate_title unless method_defined?(:__orig_generate_title)
    end
    Chat.class_eval do
      define_method(:stream_assistant_response) do |*_, **__, &block|
        events.each { |ev| block&.call(ev) }
        assembled
      end
      define_method(:generate_title) { |*_, **__| nil }
    end
  end

  # Yields the given deltas, then raises — the shape of a hub-side failure
  # (turn budget, provider error) as opposed to a client disconnect.
  def stub_stream_assistant_response_with_error!(deltas:, thinking:, error:)
    events = thinking.map { |t| { event: "thinking", data: { "delta" => t } } } +
             deltas.map { |d| { event: "message", data: { "delta" => d } } }
    Chat.class_eval do
      alias_method :__orig_stream_assistant_response, :stream_assistant_response unless method_defined?(:__orig_stream_assistant_response)
    end
    Chat.class_eval do
      define_method(:stream_assistant_response) do |*_, **__, &block|
        events.each { |ev| block&.call(ev) }
        raise error
      end
    end
  end

  def restore_chat_stream_assistant_response!
    if Chat.method_defined?(:__orig_stream_assistant_response)
      Chat.class_eval do
        alias_method :stream_assistant_response, :__orig_stream_assistant_response
        remove_method :__orig_stream_assistant_response
      end
    end
    if Chat.method_defined?(:__orig_generate_title)
      Chat.class_eval do
        alias_method :generate_title, :__orig_generate_title
        remove_method :__orig_generate_title
      end
    end
  end
end
