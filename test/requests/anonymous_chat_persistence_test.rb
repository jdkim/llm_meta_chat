require "test_helper"

# Anonymous-chat persistence: a visitor without a Devise session can still
# create chats, see them in the sidebar via the browser session cookie,
# and have them auto-claimed onto their account if they later sign in.
class AnonymousChatPersistenceTest < ActionDispatch::IntegrationTest
  setup do
    # Stub the upstream catalog so ChatsController#new can render without
    # talking to the meta-server.
    @noop_query = Object.new
    @noop_query.define_singleton_method(:stream) { |*, **, &_| "" }
    @noop_query.define_singleton_method(:call)   { |*, **| "" }

    # ChatsController also asks the catalog which providers the visitor has
    # no key for, to show them as locked. Empty here — these tests are about
    # anonymous chat persistence, not the picker.
    stub_request(:get, "#{Rails.configuration.llm_service_base_url}/api/llms")
      .to_return(status: 200, body: { llms: [] }.to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  test "an anonymous visitor's POST /chats stamps the new chat with the browser session_id" do
    with_stub(LlmMetaClient::ServerResource, :available_llm_families, []) do
      assert_difference -> { Chat.where(user_id: nil).count }, 1 do
        post chats_path, params: { message: "" } # bare submission; no LLM call needed
      end
    end

    chat = Chat.where(user_id: nil).last
    assert chat.session_id.present?, "anonymous chat must carry a session_id"
    assert_nil chat.user_id
  end

  test "two requests from the same browser session see the same anonymous chats in the sidebar scope" do
    with_stub(LlmMetaClient::ServerResource, :available_llm_families, []) do
      post chats_path, params: { message: "" }
      chat = Chat.where(user_id: nil).last
      # Sidebar only renders titled chats. Stamp one directly so we can
      # verify it appears in the rendered HTML on the next request.
      chat.update!(title: "anon test chat")

      get root_path
      assert_response :success
      assert_includes response.body, chat.uuid,
        "the titled anonymous chat should appear in the sidebar for the same session"
    end
  end

  test "a different browser session does NOT see another visitor's anonymous chats" do
    with_stub(LlmMetaClient::ServerResource, :available_llm_families, []) do
      post chats_path, params: { message: "" }
      chat_a = Chat.where(user_id: nil).last
      chat_a.update!(title: "session A chat")

      sess_b = open_session
      sess_b.get root_path
      assert_not_includes sess_b.response.body, chat_a.uuid,
        "another browser session must NOT see session A's anonymous chats"
    end
  end

  test "an anonymous visitor can NOT view another session's anonymous chat by UUID" do
    with_stub(LlmMetaClient::ServerResource, :available_llm_families, []) do
      post chats_path, params: { message: "" }
      chat_a = Chat.where(user_id: nil).last

      sess_b = open_session
      sess_b.get chat_path(chat_a.uuid)
      # The show action rescues RecordNotFound → redirect_to root_path
      # with an alert, never leaking the chat content. Use sess_b's own
      # assertion helper since the redirect lives in sess_b's response.
      sess_b.assert_redirected_to sess_b.send(:root_path)
    end
  end

  test "an anonymous visitor can delete their own chat (same session)" do
    with_stub(LlmMetaClient::ServerResource, :available_llm_families, []) do
      post chats_path, params: { message: "" }
      chat = Chat.where(user_id: nil).last

      assert_difference -> { Chat.count }, -1 do
        delete chat_path(chat.uuid)
      end
    end
  end

  test "an anonymous visitor can NOT delete another session's anonymous chat" do
    with_stub(LlmMetaClient::ServerResource, :available_llm_families, []) do
      post chats_path, params: { message: "" }
      chat_a = Chat.where(user_id: nil).last

      sess_b = open_session
      sess_b.delete chat_path(chat_a.uuid)
      # Destroy is a no-op for foreign chats (scope.find_by returns nil).
      assert Chat.exists?(chat_a.id), "session B must not be able to delete session A's chat"
    end
  end

  test "signing in auto-claims any anonymous chats created in the same browser session" do
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "claim-uid",
      info: { email: "claim@example.com" },
      credentials: { refresh_token: "rt", expires_at: 1.hour.from_now.to_i },
      extra: { id_token: "id-tok" }
    )

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, []) do
      # As anonymous: create two chats.
      post chats_path, params: { message: "" }
      post chats_path, params: { message: "" }
      anon_chats = Chat.where(user_id: nil).to_a
      assert_equal 2, anon_chats.size

      # Sign in.
      get "/users/auth/google_oauth2/callback"
      assert_redirected_to root_path

      user = User.find_by(email: "claim@example.com")
      assert user.present?, "the sign-in should have created the user"

      anon_chats.each(&:reload)
      assert anon_chats.all? { |c| c.user_id == user.id },
        "every anonymous chat from the pre-login session should be claimed"
      assert anon_chats.all? { |c| c.session_id.nil? },
        "claimed chats should clear session_id (now owned via user_id)"
    end
  ensure
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end
end
