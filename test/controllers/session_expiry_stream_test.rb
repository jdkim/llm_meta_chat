require "test_helper"

# A signed-in user whose Google id_token has expired and cannot be refreshed
# gets nil from User#jwt_token. Calling the hub without a bearer does not
# fail — it silently downgrades to the anonymous, Ollama-only path, so an
# Anthropic model came back as "Model not found: claude-fable-5-1". The model
# was present and active; the session had lapsed 16 seconds earlier.
#
# Signed in but tokenless is its own state and must say so rather than
# impersonating an anonymous visitor.
class SessionExpiryStreamTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    stub_request(:get, "#{Rails.configuration.llm_service_base_url}/api/llms")
      .to_return(status: 200, body: { llms: [] }.to_json,
                 headers: { "Content-Type" => "application/json" })
    # id_token is required at creation; the tests then expire it.
    @user = User.create!(email: "expired@example.com", google_id: "g-expired",
                         id_token: "initial", id_token_expires_at: 1.hour.from_now)
    sign_in @user
  end

  def chat_with_pending_turn
    chat = Chat.create!(user: @user)
    pe, _msg = chat.add_user_message("hello", "anthropic-key-uuid", "claude-fable-5-1",
                                     nil, llm_platform: "anthropic")
    [ chat, pe ]
  end

  test "a signed-in user with no usable token is told the session expired" do
    chat, pe = chat_with_pending_turn

    # Expired id_token, no refresh_token — exactly the production shape.
    @user.update!(id_token: "stale", refresh_token: nil, id_token_expires_at: 1.minute.ago)

    get chat_stream_path(chat.uuid), params: { execution_id: pe.execution_id },
        headers: { "Accept" => "text/event-stream" }

    assert_match(/event: error/, response.body)
    assert_match(/session_expired/, response.body)
    assert_match(/Reload the page/, response.body)
  end

  test "it does not reach the hub at all, rather than downgrading to anonymous" do
    chat, pe = chat_with_pending_turn
    @user.update!(id_token: "stale", refresh_token: nil, id_token_expires_at: 1.minute.ago)

    get chat_stream_path(chat.uuid), params: { execution_id: pe.execution_id },
        headers: { "Accept" => "text/event-stream" }

    assert_not_requested :post, %r{/chat_streams}
  end

  test "it never says the model is missing, which is what sent the real diagnosis astray" do
    chat, pe = chat_with_pending_turn
    @user.update!(id_token: "stale", refresh_token: nil, id_token_expires_at: 1.minute.ago)

    get chat_stream_path(chat.uuid), params: { execution_id: pe.execution_id },
        headers: { "Accept" => "text/event-stream" }

    assert_no_match(/Model not found/, response.body)
  end
end
