require "test_helper"

# The prompt tree has no record for "before the first prompt", so the first
# prompt became the root by accident of being first and there was nothing to
# click to begin a fresh lineage. Comparing two models on the same opening
# prompt, or two different opening prompts, meant starting a whole new chat
# and losing the grouping.
#
# The Start node is synthetic — no row, no uuid, no parent. It only parks the
# composer at Chat::ROOT_PARENT, which Chat#resolve_parent! maps to
# previous_id = nil.
class HistoryStartNodeTest < ActionDispatch::IntegrationTest
  FAMILIES = [
    { llm_type: "ollama", name: "Ollama", api_keys: [ { uuid: "ollama-local", available_models: [
      { "value" => "qwen3-8-27b", "label" => "qwen3.8:27b" },
      { "value" => "medgemma1-5-4b", "label" => "medgemma1.5:4b" }
    ] } ] }
  ].freeze

  setup do
    stub_request(:get, "#{Rails.configuration.llm_service_base_url}/api/llms")
      .to_return(status: 200, body: { llms: [] }.to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  # Create through the app so the chat carries this session's anon_chat_token;
  # otherwise visible_chats_scope hides it and the page redirects.
  def create_chat_with_one_prompt
    with_stub(LlmMetaClient::ServerResource, :available_llm_families, []) do
      post chats_path, params: { parent: Chat::ROOT_PARENT, message: "first prompt",
                                 api_key_uuid: "ollama-local", model: "qwen3-8-27b", family: "ollama" }
    end
    Chat.where(user_id: nil).order(:id).last
  end

  test "the history pane offers a Start node that parks the composer at the root" do
    chat = create_chat_with_one_prompt

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, FAMILIES) do
      get chat_path(chat.uuid)
    end

    assert_response :success
    assert_select "a.history-start-card[href=?]", chat_path(chat.uuid, from: Chat::ROOT_PARENT)
  end

  test "visiting ?from=root sets the composer's parent to the root sentinel" do
    chat = create_chat_with_one_prompt

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, FAMILIES) do
      get chat_path(chat.uuid, from: Chat::ROOT_PARENT)
    end

    assert_response :success
    assert_select "input#parent_uuid[value=?]", Chat::ROOT_PARENT
    assert_select "a.history-start-card.is-active"
  end

  test "without ?from=root the composer still continues from the tip" do
    chat = create_chat_with_one_prompt
    tip = chat.ordered_prompt_executions.last

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, FAMILIES) do
      get chat_path(chat.uuid)
    end

    assert_select "input#parent_uuid[value=?]", tip.execution_id
    assert_select "a.history-start-card.is-active", false,
                  "the Start node must not look active when composing from the tip"
  end

  test "an unknown ?from value is ignored rather than treated as a parent" do
    chat = create_chat_with_one_prompt
    tip = chat.ordered_prompt_executions.last

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, FAMILIES) do
      get chat_path(chat.uuid, from: "not-a-real-node")
    end

    assert_select "input#parent_uuid[value=?]", tip.execution_id
  end

  # The point of the whole exercise: a second root in the same chat, carrying
  # no history from the first.
  test "posting from the Start node creates a sibling root with no ancestors" do
    chat = create_chat_with_one_prompt
    first_root = chat.ordered_prompt_executions.last

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, []) do
      post add_prompt_chat_path(chat.uuid),
           params: { parent: Chat::ROOT_PARENT, message: "an unrelated question",
                     api_key_uuid: "ollama-local", model: "medgemma1-5-4b", family: "ollama" }
    end

    roots = chat.reload.ordered_prompt_executions.select { |pe| pe.previous_id.nil? }
    assert_equal 2, roots.size, "the chat should now have two independent roots"

    second_root = chat.ordered_prompt_executions.last
    assert_nil second_root.previous_id
    assert_empty second_root.build_context, "a Start-node branch must inherit no turns"
    assert_not_equal first_root.id, second_root.id
  end
end
