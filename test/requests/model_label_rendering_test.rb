require "test_helper"

# End-to-end: a rendered chat labels a turn with the model's catalog name.
# Before this, every local model was labelled "Ollama" — the platform — so a
# Qwen answer and a Llama answer were indistinguishable in the transcript and
# in the History sidebar.
class ModelLabelRenderingTest < ActionDispatch::IntegrationTest
  FAMILIES = [
    { llm_type: "ollama", name: "Ollama", api_keys: [ { uuid: "ollama-local", available_models: [
      { "value" => "qwen3-6-35b", "label" => "Qwen3.6 35B" }
    ] } ] }
  ].freeze

  setup do
    @original_labels = PromptNavigator.config.model_labels.dup
    stub_request(:get, "#{Rails.configuration.llm_service_base_url}/api/llms")
      .to_return(status: 200, body: { llms: [] }.to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  teardown { PromptNavigator.config.model_labels.replace(@original_labels) }

  # Create the chat through the app so it carries this browser session's
  # anon_chat_token — otherwise visible_chats_scope hides it and the page
  # redirects instead of rendering.
  def build_ollama_turn
    with_stub(LlmMetaClient::ServerResource, :available_llm_families, []) do
      post chats_path, params: { message: "" }
    end
    chat = Chat.where(user_id: nil).order(:id).last

    pe, _user_msg = chat.add_user_message("hello", "ollama-local", "qwen3-6-35b",
                                          nil, llm_platform: "ollama")
    pe.update!(response: "hi there")
    chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: pe)
    chat
  end

  test "the assistant bubble shows the model name, not the platform" do
    chat = build_ollama_turn

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, FAMILIES) do
      get chat_path(chat.uuid)
    end

    assert_response :success
    assert_includes response.body, "Qwen3.6 35B"
  end

  test "falls back to the platform label for a model the catalog does not list" do
    chat = build_ollama_turn
    chat.ordered_prompt_executions.last.update!(model: "some-unlisted-model")

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, FAMILIES) do
      get chat_path(chat.uuid)
    end

    assert_response :success
    assert_includes response.body, "Ollama"
  end

  # The labels used to be hand-listed in config/initializers/prompt_navigator.rb,
  # which is why a newly added model showed "Ollama": nobody had added a line
  # for it. The catalog is the source now, so this must keep working with no
  # per-model configuration anywhere.
  test "labels a model that was never hand-configured" do
    chat = build_ollama_turn
    chat.ordered_prompt_executions.last.update!(model: "qwen3-8-27b")
    families = [ { llm_type: "ollama", name: "Ollama", api_keys: [ { uuid: "ollama-local",
      available_models: [ { "value" => "qwen3-8-27b", "label" => "Qwen3.8 27B" } ] } ] } ]

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, families) do
      get chat_path(chat.uuid)
    end

    assert_includes response.body, "Qwen3.8 27B"
  end
end
