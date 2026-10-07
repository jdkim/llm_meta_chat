require "test_helper"

# A note about a chat as a whole: a hint for the audience on a demo chat, and a
# memo to self about where a conversation was left off.
#
# It lives at the top of the History pane because that pane stands for the whole
# chat — the dialogue beside it shows only one branch. Anyone who can open the
# chat can read the note; only the owner can write it.
class ChatNoteTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    stub_request(:get, "#{Rails.configuration.llm_service_base_url}/api/llms")
      .to_return(status: 200, body: { llms: [] }.to_json,
                 headers: { "Content-Type" => "application/json" })
    @owner = User.create!(email: "owner@example.com", google_id: "g-owner",
                          id_token: "good", id_token_expires_at: 1.hour.from_now)
    @other = User.create!(email: "other@example.com", google_id: "g-other",
                          id_token: "good", id_token_expires_at: 1.hour.from_now)
    @chat = Chat.create!(uuid: SecureRandom.uuid, user: @owner, title: "Demo")
  end

  # Scoped to the note block itself. The History pane and the transcript are on
  # the same page, so a body-wide match would prove nothing about where the note
  # actually rendered.
  def note_block(body)
    body[/<div class="chat-note"[^>]*>(.*?)<\/div>\s*<\/div>/m, 1]
  end

  test "the owner can write a note" do
    sign_in @owner
    patch update_note_chat_path(@chat.uuid), params: { note: "Shows branching" }

    assert_response :success
    assert_equal "Shows branching", @chat.reload.note
  end

  test "a blank note clears it rather than erroring" do
    @chat.update!(note: "old")
    sign_in @owner
    patch update_note_chat_path(@chat.uuid), params: { note: "   " }

    assert_response :success
    assert_nil @chat.reload.note
  end

  test "an over-long note is truncated, not rejected" do
    sign_in @owner
    patch update_note_chat_path(@chat.uuid), params: { note: "x" * 3000 }

    assert_response :success
    assert_equal ChatsController::NOTE_LIMIT, @chat.reload.note.length
  end

  test "a signed-in non-owner cannot write a note, even on a public chat" do
    @chat.update!(public: true, note: "mine")
    sign_in @other
    patch update_note_chat_path(@chat.uuid), params: { note: "theirs" }

    assert_response :not_found
    assert_equal "mine", @chat.reload.note
  end

  test "an audience reading a public demo chat sees the note" do
    @chat.update!(public: true, note: "Shows how one prompt can branch")
    sign_in @other

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, []) do
      get chat_path(@chat.uuid)
    end

    assert_response :success
    assert_includes note_block(response.body).to_s, "Shows how one prompt can branch"
  end

  # The note is the hint; an editor that 404s on save would not be.
  test "a non-owner gets no editor" do
    @chat.update!(public: true, note: "Shows branching")
    sign_in @other

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, []) do
      get chat_path(@chat.uuid)
    end

    refute_includes note_block(response.body).to_s, "chat-note-input"
    refute_includes note_block(response.body).to_s, "Edit note"
  end

  test "the owner gets an editor, and an invitation when there is no note yet" do
    sign_in @owner

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, []) do
      get chat_path(@chat.uuid)
    end

    block = note_block(response.body).to_s
    assert_includes block, "chat-note-input"
    assert_includes block, "+ Add a note"
  end

  test "a chat with no note shows nothing to an audience" do
    @chat.update!(public: true, note: nil)
    sign_in @other

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, []) do
      get chat_path(@chat.uuid)
    end

    assert_nil note_block(response.body)
  end

  # The pane is three sections in a fixed order: title, note, history. It used to
  # lead with the "History" heading and then show the note, so it announced one
  # thing and displayed another before any history appeared.
  test "the pane shows the title, then the note, then the history" do
    @chat.update!(public: true, note: "What this demo shows")
    sign_in @other

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, []) do
      get chat_path(@chat.uuid)
    end

    body  = response.body
    title = body.index(%q(class="pane-chat-title"))
    note  = body.index(%q(class="chat-note"))
    hist  = body.index(%q(class="history-heading"))

    assert title, "the pane should show the chat's title"
    assert note,  "the pane should show the note"
    assert hist,  "the pane should still have its History heading"
    assert_operator title, :<, note, "the title comes first"
    assert_operator note,  :<, hist, "the note comes before the history"
  end

  test "an untitled chat simply omits the title section" do
    @chat.update!(public: true, title: nil, note: "still has a note")
    sign_in @other

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, []) do
      get chat_path(@chat.uuid)
    end

    refute_includes response.body, "pane-chat-title"
    assert_includes response.body, "still has a note"
  end
end
