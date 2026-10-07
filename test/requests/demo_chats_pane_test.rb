require "test_helper"

# The Demo chats pane lives in the layout, so it must survive every render path.
#
# Reported symptom: "sometimes the Demo Chats section disappears… I think it is
# when I submitted a new prompt." It was not intermittent. @public_chats was
# loaded by ChatsController alone, so the pane came back empty anywhere else —
# on /prompts/:id, and after a streamed answer, because
# ChatStreamsController#render_sidebar_update re-renders the whole sidebar.
class DemoChatsPaneTest < ActionDispatch::IntegrationTest
  setup do
    stub_request(:get, "#{Rails.configuration.llm_service_base_url}/api/llms")
      .to_return(status: 200, body: { llms: [] }.to_json,
                 headers: { "Content-Type" => "application/json" })
    @chat = Chat.create!(uuid: SecureRandom.uuid, title: "A demo", public: true)
    @pe, _msg = @chat.add_user_message("hello", "ollama-local", "qwen3-6-35b",
                                       nil, llm_platform: "ollama")
    @pe.update!(response: "hi")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: @pe)
  end

  def get_page(path)
    with_stub(LlmMetaClient::ServerResource, :available_llm_families, []) { get path }
  end

  test "the pane is on a chat page" do
    get_page chat_path(@chat.uuid)
    assert_includes response.body, "demo-chats-pane"
  end

  # The regression: same layout, different controller.
  test "the pane is on a prompt node page" do
    get_page prompt_path(@pe.execution_id)

    assert_response :success
    assert_includes response.body, "demo-chats-pane",
                    "PromptsController renders the same layout and must load the demo chats too"
  end

  # The streamed case, asserted where it actually breaks: the controller that
  # re-renders the sidebar has to run the filter. Driving a real SSE response
  # here would test Live rendering, not this.
  #
  # DERIVED, not a hand-written list. The bug happened because a controller was
  # added without the filter, so a test naming today's controllers would miss
  # tomorrow's. eager_load! because the test environment does not autoload
  # every controller, and `descendants` only knows what has been loaded.
  test "every controller rendering the layout loads the demo chats" do
    Rails.application.eager_load!

    offenders = ApplicationController.descendants.reject do |klass|
      klass._process_action_callbacks.map(&:filter).include?(:load_public_chats)
    end

    assert_empty offenders,
                 "these render the layout (or replace the sidebar) but never set " \
                 "@public_chats, so the Demo chats pane renders empty there: " \
                 "#{offenders.join(', ')}"
  end

  # The sidebar is REPLACED wholesale on these paths, which is what made the
  # pane vanish without any navigation. Assert the pane is in the actual
  # response, not merely that a filter is in the callback chain.
  test "the pane survives the turbo stream that replaces the sidebar" do
    post chats_path, params: { parent: Chat::ROOT_PARENT, message: "" },
                     headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_includes response.body, "chat-sidebar", "this response replaces the sidebar"
    assert_includes response.body, "demo-chats-pane",
                    "replacing the sidebar must not drop the Demo chats pane"
  end

  test "the pane survives deleting a chat" do
    doomed = Chat.create!(uuid: SecureRandom.uuid)

    delete chat_path(doomed.uuid), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_includes response.body, "demo-chats-pane"
  end
end
