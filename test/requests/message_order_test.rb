require "test_helper"

# A chat rendered its assistant reply ABOVE the prompt that produced it, and a
# reload did not fix it: the view passed `@chat.messages` — the unordered
# association — instead of the ordered collection the controller had built,
# and `includes(:messages)` issues no ORDER BY, so Postgres was free to return
# the rows either way round.
class MessageOrderTest < ActionDispatch::IntegrationTest
  setup do
    stub_request(:get, "#{Rails.configuration.llm_service_base_url}/api/llms")
      .to_return(status: 200, body: { llms: [] }.to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  def chat_with_a_turn
    with_stub(LlmMetaClient::ServerResource, :available_llm_families, []) do
      post chats_path, params: { message: "" }
    end
    chat = Chat.where(user_id: nil).order(:id).last
    pe, _user = chat.add_user_message("the question", "ollama-local", "qwen3-8-27b",
                                      nil, llm_platform: "ollama")
    pe.update!(response: "the answer")
    chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: pe)
    chat
  end

  test "the association returns the prompt before the reply" do
    chat = chat_with_a_turn

    assert_equal %w[user assistant], chat.reload.messages.map(&:role)
  end

  test "the association stays ordered when preloaded, which is how #show loads it" do
    chat = chat_with_a_turn

    preloaded = Chat.includes(:messages).find(chat.id)

    assert_equal %w[user assistant], preloaded.messages.map(&:role)
  end

  test "an anonymous visitor sees the prompt above the reply" do
    chat = chat_with_a_turn

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, []) do
      get chat_path(chat.uuid)
    end

    assert_response :success
    rendered = response.body.scan(/class="message (user|assistant)"/).flatten
    assert_equal %w[user assistant], rendered,
                 "the transcript must render in conversation order"
  end
end
