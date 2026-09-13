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
    assert_select ".history-card.history-card-start a.history-card-link[href=?]",
                  chat_path(chat.uuid, from: Chat::ROOT_PARENT)
  end

  test "visiting ?from=root sets the composer's parent to the root sentinel" do
    chat = create_chat_with_one_prompt

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, FAMILIES) do
      get chat_path(chat.uuid, from: Chat::ROOT_PARENT)
    end

    assert_response :success
    assert_select "input#parent_uuid[value=?]", Chat::ROOT_PARENT
    assert_select ".history-card.history-card-start.is-active"
  end

  test "without ?from=root the composer still continues from the tip" do
    chat = create_chat_with_one_prompt
    tip = chat.ordered_prompt_executions.last

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, FAMILIES) do
      get chat_path(chat.uuid)
    end

    assert_select "input#parent_uuid[value=?]", tip.execution_id
    assert_select ".history-card.history-card-start.is-active", false,
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

  # The Start node used to sit outside the arrow canvas as its own kind of
  # element, so the tree appeared to have as many top-level entries as it had
  # roots, with nothing explaining where they came from. It is now an ordinary
  # card inside the stack, and every root points at it.
  test "the Start node renders as an ordinary card inside the arrow canvas" do
    chat = create_chat_with_one_prompt

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, FAMILIES) do
      get chat_path(chat.uuid)
    end

    assert_select "#history-stack .history-card.history-card-start[data-uuid=?]",
                  Chat::ROOT_PARENT
    # data-history-target="cards" is what puts it in history_controller's map,
    # which is what lets an arrow terminate on it.
    assert_select ".history-card-start[data-history-target=?]", "cards"
    # No delete affordance and no model badge — it is not a prompt execution.
    assert_select ".history-card-start .history-card-delete", false
    assert_select ".history-card-start .history-card-platform-label", false
  end

  test "the first root names the Start node as its parent" do
    chat = create_chat_with_one_prompt
    root = chat.ordered_prompt_executions.first

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, FAMILIES) do
      get chat_path(chat.uuid)
    end

    assert_select ".history-card[data-uuid=?][data-parent-uuid=?]",
                  root.execution_id, Chat::ROOT_PARENT
  end

  # Oldest-first ordering puts a parent above its child, so the connector
  # between adjacent cards points down. The gem's partial pointed it up, which
  # was right only for the descending layout this app moved away from.
  test "adjacent cards are connected by a downward arrow" do
    chat = create_chat_with_one_prompt
    root = chat.ordered_prompt_executions.first
    # A chained follow-up is required: with a single prompt the only connector
    # on the page is the pane's own Start arrow, so the card partial's
    # connector would go untested and a regression there would pass.
    with_stub(LlmMetaClient::ServerResource, :available_llm_families, []) do
      post add_prompt_chat_path(chat.uuid),
           params: { parent: root.execution_id, message: "a follow-up",
                     api_key_uuid: "ollama-local", model: "qwen3-8-27b", family: "ollama" }
    end

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, FAMILIES) do
      get chat_path(chat.uuid)
    end

    # Start -> root, and root -> its child.
    assert_select ".history-straight-arrow", text: "↓", count: 2
    assert_select ".history-straight-arrow", text: "↑", count: 0
  end

  test "every root points at the Start node, so the tree has one origin" do
    chat = create_chat_with_one_prompt
    with_stub(LlmMetaClient::ServerResource, :available_llm_families, []) do
      post add_prompt_chat_path(chat.uuid),
           params: { parent: Chat::ROOT_PARENT, message: "an unrelated question",
                     api_key_uuid: "ollama-local", model: "medgemma1-5-4b", family: "ollama" }
    end

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, FAMILIES) do
      get chat_path(chat.uuid)
    end

    roots = chat.reload.ordered_prompt_executions.select { |pe| pe.previous_id.nil? }
    assert_equal 2, roots.size
    roots.each do |root|
      assert_select ".history-card[data-uuid=?][data-parent-uuid=?]",
                    root.execution_id, Chat::ROOT_PARENT
    end
  end

  # A child must still point at its real parent, not get swept up by the
  # root rule above.
  test "a non-root card keeps its real parent" do
    chat = create_chat_with_one_prompt
    root = chat.ordered_prompt_executions.first
    with_stub(LlmMetaClient::ServerResource, :available_llm_families, []) do
      post add_prompt_chat_path(chat.uuid),
           params: { parent: root.execution_id, message: "a follow-up",
                     api_key_uuid: "ollama-local", model: "qwen3-8-27b", family: "ollama" }
    end

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, FAMILIES) do
      get chat_path(chat.uuid)
    end

    child = chat.reload.ordered_prompt_executions.find { |pe| pe.previous_id == root.id }
    assert_not_nil child
    assert_select ".history-card[data-uuid=?][data-parent-uuid=?]",
                  child.execution_id, root.execution_id
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
