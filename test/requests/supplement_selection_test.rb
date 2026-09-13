require "test_helper"

# End-to-end wiring for citing history nodes: the hidden field the JS writes,
# the params reaching the controller, and the edges that come out.
#
# The security property is the one worth the most here — an execution_id from
# another chat must not become a citation, because the injected block would
# then carry a stranger's content into this conversation's context.
class SupplementSelectionTest < ActionDispatch::IntegrationTest
  FAMILIES = [
    { llm_type: "ollama", name: "Ollama", api_keys: [ { uuid: "ollama-local", available_models: [
      { "value" => "qwen3-8-27b", "label" => "qwen3.8:27b" }
    ] } ] }
  ].freeze

  setup do
    stub_request(:get, "#{Rails.configuration.llm_service_base_url}/api/llms")
      .to_return(status: 200, body: { llms: [] }.to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  def create_chat_with_one_prompt(message: "first prompt")
    with_stub(LlmMetaClient::ServerResource, :available_llm_families, []) do
      post chats_path, params: { parent: Chat::ROOT_PARENT, message: message,
                                 api_key_uuid: "ollama-local", model: "qwen3-8-27b", family: "ollama" }
    end
    Chat.where(user_id: nil).order(:id).last
  end

  def add_prompt(chat, message:, parent:, supplements: nil)
    params = { parent: parent, message: message,
               api_key_uuid: "ollama-local", model: "qwen3-8-27b", family: "ollama" }
    params[:supplements] = supplements if supplements
    with_stub(LlmMetaClient::ServerResource, :available_llm_families, []) do
      post add_prompt_chat_path(chat.uuid), params: params
    end
  end

  test "the composer carries the hidden field the selection writes into" do
    chat = create_chat_with_one_prompt

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, FAMILIES) do
      get chat_path(chat.uuid)
    end

    assert_response :success
    assert_select "input#supplement_uuids[data-supplements-target=?]", "field"
    assert_select "[data-supplements-target=?]", "chips"
    assert_select "[data-supplements-target=?]", "presets"
  end

  # The gesture is invisible without them, and they are the only way to drop a
  # citation without going back to the card.
  test "both presets are offered, each carrying editable wording" do
    chat = create_chat_with_one_prompt

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, FAMILIES) do
      get chat_path(chat.uuid)
    end

    assert_select "button.supplement-preset", count: 2
    assert_select "button.supplement-preset[data-preset*=?]", "referenced material"
    assert_select "button.supplement-preset[data-preset*=?]", "supplementary perspectives"
  end

  # A citation is reference material; the node the composer sits on is not — it
  # reaches the model as dialogue. The preset has to name both sides, or the
  # user cannot tell what is being compared with what.
  test "the compare preset names the previous answer as the other side" do
    chat = create_chat_with_one_prompt
    root = chat.ordered_prompt_executions.first

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, FAMILIES) do
      get chat_path(chat.uuid, from: root.execution_id)
    end

    assert_select "button.supplement-preset[data-preset*=?]", "your previous answer"
  end

  # From the empty state there is no previous answer to compare against, so the
  # wording must not promise one.
  test "the compare preset drops that phrasing at the root" do
    chat = create_chat_with_one_prompt

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, FAMILIES) do
      get chat_path(chat.uuid, from: Chat::ROOT_PARENT)
    end

    assert_select "button.supplement-preset[data-preset*=?]", "Compare the referenced material"
    assert_select "button.supplement-preset[data-preset*=?]", "your previous answer", false
  end

  # Found in testing: answers are much easier to read back when the model names
  # which one it is discussing. The block labels them, but nothing asked the
  # model to use those labels.
  test "both presets ask the model to attribute answers by model name" do
    chat = create_chat_with_one_prompt

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, FAMILIES) do
      get chat_path(chat.uuid)
    end

    assert_select "button.supplement-preset", count: 2
    assert_select "button.supplement-preset[data-preset*=?]", "by its model name", count: 2
  end

  # The stored prompt is only what was typed, so without this the transcript
  # showed less than the model was actually given.
  test "a user turn shows the material it carried" do
    chat = create_chat_with_one_prompt(message: "what is aibranch?")
    cited = chat.ordered_prompt_executions.first
    cited.update!(response: "A branching chat UI.", model: "qwen3-8-27b")
    add_prompt(chat, message: "compare", parent: cited.execution_id, supplements: cited.execution_id)

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, FAMILIES) do
      get chat_path(chat.uuid)
    end

    assert_select "details.message-references summary", text: /Referenced material \(1\)/
    assert_select "details.message-references pre", text: /\[1\] qwen3-8-27b — A branching chat UI\./
  end

  test "a user turn with no citations shows no such section" do
    chat = create_chat_with_one_prompt
    root = chat.ordered_prompt_executions.first
    add_prompt(chat, message: "plain", parent: root.execution_id)

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, FAMILIES) do
      get chat_path(chat.uuid)
    end

    assert_select "details.message-references", false
  end

  test "the composer explains where a citation is delivered" do
    chat = create_chat_with_one_prompt

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, FAMILIES) do
      get chat_path(chat.uuid)
    end

    assert_select "[data-supplements-target=?]", "note"
  end

  test "posting with supplements records the citations on the new prompt" do
    chat = create_chat_with_one_prompt
    root = chat.ordered_prompt_executions.first
    add_prompt(chat, message: "second", parent: Chat::ROOT_PARENT)
    second = chat.reload.ordered_prompt_executions.last

    add_prompt(chat, message: "compare them", parent: root.execution_id,
               supplements: "#{second.execution_id}")

    cited = chat.reload.ordered_prompt_executions.last
    assert_equal [ second.id ], cited.supplements.map(&:id)
  end

  # The security property.
  test "an execution_id from another chat is ignored, not cited" do
    mine   = create_chat_with_one_prompt(message: "mine")
    theirs = create_chat_with_one_prompt(message: "theirs")
    stranger = theirs.ordered_prompt_executions.first
    root = mine.ordered_prompt_executions.first

    add_prompt(mine, message: "sneak", parent: root.execution_id,
               supplements: stranger.execution_id)

    created = mine.reload.ordered_prompt_executions.last
    assert_empty created.supplements,
                 "a node from another chat must never become a citation"
  end

  test "posting without the param records no citations" do
    chat = create_chat_with_one_prompt
    root = chat.ordered_prompt_executions.first

    add_prompt(chat, message: "plain", parent: root.execution_id)

    assert_empty chat.reload.ordered_prompt_executions.last.supplements
  end

  # The arrow renderer reads this attribute off each card; without it every
  # reference arrow silently disappears.
  test "a citing prompt's card exposes the cited uuids to the arrow renderer" do
    chat = create_chat_with_one_prompt
    root = chat.ordered_prompt_executions.first
    add_prompt(chat, message: "second", parent: Chat::ROOT_PARENT)
    second = chat.reload.ordered_prompt_executions.last
    add_prompt(chat, message: "compare", parent: root.execution_id,
               supplements: second.execution_id)
    citing = chat.reload.ordered_prompt_executions.last

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, FAMILIES) do
      get chat_path(chat.uuid)
    end

    assert_select ".history-card[data-uuid=?][data-supplement-uuids=?]",
                  citing.execution_id, second.execution_id
  end

  test "exceeding the cap is reported rather than silently truncated" do
    chat = create_chat_with_one_prompt
    root = chat.ordered_prompt_executions.first
    ids = (Chat::MAX_SUPPLEMENTS + 1).times.map do |i|
      add_prompt(chat, message: "p#{i}", parent: Chat::ROOT_PARENT)
      chat.reload.ordered_prompt_executions.last.execution_id
    end

    add_prompt(chat, message: "too many", parent: root.execution_id, supplements: ids.join(","))

    # The prompt is refused, so no new execution is created for it.
    assert_not_equal "too many", chat.reload.ordered_prompt_executions.last.prompt
  end

  # ----- preview endpoint -----

  # The panel exists so the mechanism is not invisible; it must show the real
  # block, which is why it is fetched rather than reconstructed client-side.
  test "the preview renders the block a selection would send" do
    chat = create_chat_with_one_prompt(message: "what is aibranch?")
    cited = chat.ordered_prompt_executions.first
    cited.update!(response: "AIbranch is a branching chat UI.", model: "qwen3-8-27b")

    get reference_preview_chat_path(chat.uuid), params: { supplements: cited.execution_id }

    assert_response :success
    assert_includes response.body, "Referenced material"
    assert_includes response.body, "Question: what is aibranch?"
    assert_includes response.body, "[1] qwen3-8-27b — AIbranch is a branching chat UI."
  end

  # Same rendering path as the send side. If these diverge the preview is worse
  # than showing nothing, because it would be confidently wrong.
  test "the preview matches what the prompt actually carries" do
    chat = create_chat_with_one_prompt(message: "shared question")
    cited = chat.ordered_prompt_executions.first
    cited.update!(response: "an answer", model: "m1")

    get reference_preview_chat_path(chat.uuid), params: { supplements: cited.execution_id }
    previewed = response.body

    add_prompt(chat, message: "go", parent: cited.execution_id, supplements: cited.execution_id)
    sent = chat.reload.send(:prepend_reference_block, chat.ordered_prompt_executions.last, "go")

    assert_includes sent, previewed.strip
  end

  # The endpoint takes ids, so it would otherwise be a second way in.
  test "the preview refuses to show a node from another chat" do
    mine   = create_chat_with_one_prompt(message: "mine")
    theirs = create_chat_with_one_prompt(message: "a stranger's prompt")
    stranger = theirs.ordered_prompt_executions.first
    stranger.update!(response: "a stranger's answer")

    get reference_preview_chat_path(mine.uuid), params: { supplements: stranger.execution_id }

    assert_response :success
    assert_not_includes response.body, "a stranger's answer"
    assert_not_includes response.body, "a stranger's prompt"
  end

  test "the preview is empty when nothing is selected" do
    chat = create_chat_with_one_prompt

    get reference_preview_chat_path(chat.uuid), params: { supplements: "" }

    assert_response :success
    assert_equal "", response.body.strip
  end

  test "the preview reports an over-cap selection rather than rendering it" do
    chat = create_chat_with_one_prompt
    ids = (Chat::MAX_SUPPLEMENTS + 1).times.map do |i|
      add_prompt(chat, message: "p#{i}", parent: Chat::ROOT_PARENT)
      chat.reload.ordered_prompt_executions.last.execution_id
    end

    get reference_preview_chat_path(chat.uuid), params: { supplements: ids.join(",") }

    assert_response :unprocessable_entity
  end

  test "the composer offers the reveal control and the preview panel" do
    chat = create_chat_with_one_prompt

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, FAMILIES) do
      get chat_path(chat.uuid)
    end

    assert_select "[data-supplements-target=?]", "reveal"
    assert_select "pre[data-supplements-target=?][data-preview-url=?]",
                  "preview", reference_preview_chat_path(chat.uuid)
  end

  # ----- deleting a node that is involved in a citation -----

  # Hit in dev: the per-card delete used a raw `pe.delete`, which bypasses
  # callbacks so `dependent:` never fires. The supplement edges are a foreign
  # key into the executions table, so the delete failed with
  # PG::ForeignKeyViolation and the user could not remove the node at all.
  test "a leaf that cites another node can still be deleted" do
    chat = create_chat_with_one_prompt(message: "root")
    root = chat.ordered_prompt_executions.first
    add_prompt(chat, message: "citing", parent: root.execution_id, supplements: root.execution_id)
    citing = chat.reload.ordered_prompt_executions.last
    assert_equal [ root.id ], citing.supplements.map(&:id), "fixture should have a citation"

    delete prompt_path(citing.execution_id)

    assert_response :redirect
    assert_not PromptNavigator::PromptExecution.exists?(citing.id)
    assert_equal 0, PromptNavigator::Supplement.where(prompt_execution_id: citing.id).count
  end

  # The other direction: the node being deleted is the one someone cites.
  test "a leaf that another prompt cites can still be deleted" do
    chat = create_chat_with_one_prompt(message: "root")
    root = chat.ordered_prompt_executions.first
    add_prompt(chat, message: "sibling", parent: Chat::ROOT_PARENT)
    cited = chat.reload.ordered_prompt_executions.last
    add_prompt(chat, message: "citing", parent: root.execution_id, supplements: cited.execution_id)
    citing = chat.reload.ordered_prompt_executions.last

    delete prompt_path(cited.execution_id)

    assert_response :redirect
    assert_not PromptNavigator::PromptExecution.exists?(cited.id)
    # The citing prompt survives, having simply lost the reference — a citation
    # is a soft reference, unlike lineage.
    assert PromptNavigator::PromptExecution.exists?(citing.id)
    assert_empty citing.reload.supplements
  end

  test "deleting an uncited leaf still works" do
    chat = create_chat_with_one_prompt(message: "root")
    root = chat.ordered_prompt_executions.first
    add_prompt(chat, message: "plain", parent: root.execution_id)
    leaf = chat.reload.ordered_prompt_executions.last

    delete prompt_path(leaf.execution_id)

    assert_response :redirect
    assert_not PromptNavigator::PromptExecution.exists?(leaf.id)
  end
end
