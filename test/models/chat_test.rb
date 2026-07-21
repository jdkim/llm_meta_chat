require "test_helper"

# Tests for the Chat model — the consumer-side domain logic that wires
# user messages through to the meta-server. Two real bugs sat on this
# code path:
#
#   1. "Undefined Image" titles when raw image markdown was handed to the
#      summarizer (fixed in summarize_for_title by extract_attached_image).
#   2. Image bytes lost on chat reload (fixed by prefixing the data-URI
#      markdown into the persisted prompt in add_user_message).
#
# The tests below pin those plus the conversation-context summarization
# decisions in build_streaming_context, since that's where token budget
# regressions silently cost money on every chat.
class ChatTest < ActiveSupport::TestCase
  setup do
    @chat = Chat.create!
  end

  # ----- set_uuid + basic AR ----- #

  test "before_create assigns a UUID to the chat" do
    chat = Chat.create!
    assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, chat.uuid)
  end

  # ----- add_user_message ----- #

  test "add_user_message creates a PromptExecution + user Message, returning both" do
    pe, msg = @chat.add_user_message("hello", "key-1", "gpt-5", nil, llm_platform: "openai")

    assert pe.persisted?
    assert msg.persisted?
    assert_equal "hello", pe.prompt
    assert_equal "user", msg.role
    assert_equal pe.id, msg.prompt_navigator_prompt_execution_id
    assert_equal "key-1", pe.llm_uuid
    assert_equal "gpt-5", pe.model
    assert_equal "openai", pe.llm_platform
  end

  test "add_user_message links to the previous user message's prompt_execution" do
    pe1, _msg1 = @chat.add_user_message("first", "key-1", "gpt-5")
    pe2, _msg2 = @chat.add_user_message("second", "key-1", "gpt-5")

    assert_equal pe1.id, pe2.previous_id,
      "the second turn must chain off the first user turn's PE"
  end

  test "add_user_message branches off the explicit branch_from_execution_id when given" do
    pe1, _msg1 = @chat.add_user_message("first", "key-1", "gpt-5")
    _pe2, _msg2 = @chat.add_user_message("second", "key-1", "gpt-5")
    pe3, _msg3 = @chat.add_user_message("branch", "key-1", "gpt-5", pe1.execution_id)

    # pe3 forks off pe1, NOT pe2.
    assert_equal pe1.id, pe3.previous_id
  end

  test "add_user_message prepends the attached image as data-URI markdown so it survives reload" do
    pe, _msg = @chat.add_user_message("describe it", "key-1", "gpt-5", nil,
                                       image: { mime: "image/png", data_b64: "AAA" })

    assert_match(/\A!\[\]\(data:image\/png;base64,AAA\)/, pe.prompt)
    assert_includes pe.prompt, "describe it"
  end

  test "add_user_message prepends the attached document as data-URI markdown link" do
    pe, _msg = @chat.add_user_message("summarize this", "key-1", "gpt-5", nil,
                                       document: { mime: "text/csv", data_b64: "YSxi", filename: "data.csv" })

    assert_match(/\A\[data\.csv\]\(data:text\/csv;base64,YSxi\)/, pe.prompt)
    assert_includes pe.prompt, "summarize this"
  end

  test "add_user_message: image wins when both image and document are supplied" do
    pe, _msg = @chat.add_user_message("both", "k", "gpt-5", nil,
                                       image: { mime: "image/png", data_b64: "P" },
                                       document: { mime: "text/plain", data_b64: "Q", filename: "f.txt" })
    assert_match(/\A!\[\]\(data:image\/png;base64,P\)/, pe.prompt)
    refute_match(/\A\[f\.txt\]/, pe.prompt)
  end

  test "extract_attached_document pulls a leading text-doc link into a structured hash" do
    text, doc = @chat.send(:extract_attached_document,
                            "[notes.md](data:text/markdown;base64,SGVsbG8=)what does this say?")
    assert_equal "what does this say?", text
    assert_equal({ filename: "notes.md", mime: "text/markdown", data_b64: "SGVsbG8=" }, doc)
  end

  test "extract_attached_document ignores images (leading `!`)" do
    text, doc = @chat.send(:extract_attached_document,
                            "![](data:image/png;base64,AAA)caption")
    assert_equal "![](data:image/png;base64,AAA)caption", text
    assert_nil doc
  end

  test "inline_document_content wraps decoded content in a fenced code block with lang hint" do
    doc = { filename: "data.csv", mime: "text/csv", data_b64: Base64.strict_encode64("a,b\n1,2") }
    out = @chat.send(:inline_document_content, doc, "please summarize")
    assert_includes out, "Attached: data.csv"
    assert_includes out, "```csv"
    assert_includes out, "a,b\n1,2"
    assert_includes out, "please summarize"
  end

  test "inline_document_content falls back to 'text' lang when filename has no extension" do
    doc = { filename: "notes", mime: "text/plain", data_b64: Base64.strict_encode64("hello") }
    out = @chat.send(:inline_document_content, doc, "what is this")
    assert_includes out, "```text"
  end

  test "inline_document_content returns user_text unchanged when decoded content isn't valid UTF-8" do
    invalid_utf8 = "\xC3\x28" # a lone continuation byte — invalid UTF-8
    doc = { filename: "bad.txt", mime: "text/plain", data_b64: Base64.strict_encode64(invalid_utf8) }
    out = @chat.send(:inline_document_content, doc, "user asked something")
    assert_equal "user asked something", out
  end

  test "extract_attached_document does NOT match a link in the middle of the prompt" do
    text, doc = @chat.send(:extract_attached_document,
                            "hi [notes.md](data:text/markdown;base64,QQ==) look")
    assert_equal "hi [notes.md](data:text/markdown;base64,QQ==) look", text
    assert_nil doc
  end

  test "add_user_message + extract_attached_document round-trip preserves the doc" do
    pe, _msg = @chat.add_user_message("summarize this", "k", "gpt-5", nil,
                                       document: { mime: "text/csv", data_b64: "YSxi", filename: "data.csv" })
    text, doc = @chat.send(:extract_attached_document, pe.prompt)
    assert_equal "summarize this", text
    assert_equal({ filename: "data.csv", mime: "text/csv", data_b64: "YSxi" }, doc)
  end

  test "strip_inline_attachments replaces embedded doc data URIs with [document: filename]" do
    stripped = @chat.send(:strip_inline_attachments,
                          "before [notes.md](data:text/markdown;base64,AAA) after")
    assert_equal "before [document: notes.md] after", stripped
  end

  test "strip_inline_attachments preserves regular markdown links (non-data URIs)" do
    stripped = @chat.send(:strip_inline_attachments, "see [docs](https://example.org/x)")
    assert_equal "see [docs](https://example.org/x)", stripped
  end

  test "strip_inline_attachments strips both image and doc data URIs in one turn" do
    stripped = @chat.send(:strip_inline_attachments,
                          "![](data:image/png;base64,X) and [a.csv](data:text/csv;base64,Y)")
    assert_equal "[image] and [document: a.csv]", stripped
  end

  test "summarize_for_title strips document data URI before checking blank" do
    # A prompt that is ONLY a document attachment (no user text) should return
    # nil — the summarizer has nothing meaningful to work with.
    prompt = "[notes.md](data:text/markdown;base64,QQ==)"
    assert_nil @chat.send(:summarize_for_title, prompt, "jwt")
  end

  test "pdf_document? returns true for application/pdf mime, false for text mimes" do
    assert @chat.send(:pdf_document?, { mime: "application/pdf", data_b64: "X" })
    refute @chat.send(:pdf_document?, { mime: "text/markdown", data_b64: "Y" })
    refute @chat.send(:pdf_document?, { mime: "text/plain", data_b64: "Z" })
    refute @chat.send(:pdf_document?, nil)
  end

  # ----- ordered_messages + ordered_prompt_executions ----- #

  test "ordered_messages returns messages in created_at ascending order" do
    pe1, m1 = @chat.add_user_message("first", "k", "gpt-5")
    pe2, m2 = @chat.add_user_message("second", "k", "gpt-5")

    ordered = @chat.ordered_messages.to_a
    assert_equal [ m1.id, m2.id ], ordered.map(&:id)
  end

  test "ordered_prompt_executions returns only user-role PEs, oldest first" do
    pe1, m1 = @chat.add_user_message("first", "k", "gpt-5")
    # Manually add an assistant message — shouldn't appear in this list.
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: pe1)
    pe2, _m2 = @chat.add_user_message("second", "k", "gpt-5")

    pes = @chat.ordered_prompt_executions
    assert_equal [ pe1.id, pe2.id ], pes.map(&:id)
  end

  # ----- extract_attached_image (private) ----- #

  test "extract_attached_image pulls a leading image into a structured hash" do
    text, image = @chat.send(:extract_attached_image,
                              "![](data:image/png;base64,XYZ)what is this?")
    assert_equal "what is this?", text
    assert_equal({ mime: "image/png", data_b64: "XYZ" }, image)
  end

  test "extract_attached_image returns [original, nil] when no leading image" do
    text, image = @chat.send(:extract_attached_image, "no image here")
    assert_equal "no image here", text
    assert_nil image
  end

  test "extract_attached_image does NOT match an image in the middle of the prompt" do
    text, image = @chat.send(:extract_attached_image,
                              "prefix ![](data:image/png;base64,X)")
    assert_equal "prefix ![](data:image/png;base64,X)", text
    assert_nil image
  end

  test "extract_attached_image consumes whitespace/newlines between image and text" do
    text, _image = @chat.send(:extract_attached_image,
                               "![](data:image/png;base64,X)\n\ndescribe")
    assert_equal "describe", text
  end

  # ----- image_model? (private) ----- #

  test "image_model? is true for meta_ids containing 'image'" do
    assert @chat.send(:image_model?, "gemini-3-pro-image")
    assert @chat.send(:image_model?, "gemini-2-5-flash-image")
  end

  test "image_model? is false for non-image meta_ids" do
    refute @chat.send(:image_model?, "gpt-5")
    refute @chat.send(:image_model?, "claude-opus-4-7")
  end

  # (format_transcript was removed in Phase 4 — history now goes as
  # role-tagged messages, not a "User: /Assistant:" concatenated string.
  # See the build_streaming_messages block below.)

  test "strip_inline_images_in_turn rewrites both prompt and response" do
    stripped = @chat.send(:strip_inline_images_in_turn,
      { prompt: "![](data:image/png;base64,AA) text", response: "look at ![](data:image/jpeg;base64,BB)" }
    )
    assert_equal "[image] text", stripped[:prompt]
    assert_equal "look at [image]", stripped[:response]
  end

  # ----- collect_recent_images (private) ----- #

  test "collect_recent_images returns chronological list capped at HISTORICAL_IMAGE_LIMIT + current" do
    # Build a 4-turn lineage: image, no-image, image, image — then call from
    # a hypothetical "next" PE that points to the most recent turn.
    pe1, _ = @chat.add_user_message("![](data:image/png;base64,IMG1) q1", "key", "gpt-5")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: pe1)
    pe2, _ = @chat.add_user_message("q2 no image", "key", "gpt-5")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: pe2)
    pe3, _ = @chat.add_user_message("![](data:image/png;base64,IMG3) q3", "key", "gpt-5")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: pe3)
    pe4, _ = @chat.add_user_message("![](data:image/png;base64,IMG4) q4", "key", "gpt-5")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: pe4)

    # Stand on a future "current" turn whose previous is pe4. Cap = 2, so we
    # take pe4 + pe3 from history (IMG3, IMG4 chronologically) and append the
    # current image last.
    next_pe = PromptNavigator::PromptExecution.new(prompt: "current", previous: pe4)
    result = @chat.send(:collect_recent_images, next_pe,
                        current_image: { mime: "image/png", data_b64: "CUR" })

    assert_equal 3, result.size
    assert_equal [ "IMG3", "IMG4", "CUR" ], result.map { |i| i[:data_b64] }
  end

  test "collect_recent_images returns just the current image when history has none" do
    pe, _ = @chat.add_user_message("hi", "key", "gpt-5")
    next_pe = PromptNavigator::PromptExecution.new(prompt: "next", previous: pe)
    result = @chat.send(:collect_recent_images, next_pe,
                        current_image: { mime: "image/png", data_b64: "CUR" })
    assert_equal [ "CUR" ], result.map { |i| i[:data_b64] }
  end

  test "collect_recent_images returns empty list when no images anywhere" do
    pe, _ = @chat.add_user_message("hi", "key", "gpt-5")
    next_pe = PromptNavigator::PromptExecution.new(prompt: "next", previous: pe)
    assert_empty @chat.send(:collect_recent_images, next_pe, current_image: nil)
  end

  test "collect_recent_images follows the branch chain, not the chat's global chronology" do
    # Trunk: text-only → image — chronologically present in the chat but
    # NOT on the branch we'll send from.
    trunk_a, _ = @chat.add_user_message("trunk text", "key", "gpt-5")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: trunk_a)
    trunk_b, _ = @chat.add_user_message("![](data:image/png;base64,TRUNK) trunk picture", "key", "gpt-5")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: trunk_b)

    # Branch off trunk_a (the FIRST trunk PE), with one image.
    branch, _ = @chat.add_user_message(
      "![](data:image/png;base64,BRANCH) branch picture",
      "key", "gpt-5",
      trunk_a.execution_id
    )
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: branch)

    # New prompt sent from the branch tip — its `previous` is `branch`.
    next_pe = PromptNavigator::PromptExecution.new(prompt: "follow-up on branch", previous: branch)
    result = @chat.send(:collect_recent_images, next_pe,
                        current_image: { mime: "image/png", data_b64: "CUR" })

    # Should pick up only the branch's image + current. trunk_b's image is on
    # a different branch and must not leak in.
    data = result.map { |i| i[:data_b64] }
    assert_equal [ "BRANCH", "CUR" ], data
    refute_includes data, "TRUNK"
  end

  test "collect_recent_images caps at HISTORICAL_IMAGE_LIMIT on a branched lineage (most recent wins)" do
    # Off-branch trunk image — must be invisible.
    trunk_a, _ = @chat.add_user_message("![](data:image/png;base64,TRUNK) trunk", "key", "gpt-5")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: trunk_a)

    # Build a branch off trunk_a with four image-bearing PEs in a row:
    # R (oldest on branch) → X → Y → Z (newest on branch).
    img_r, _ = @chat.add_user_message("![](data:image/png;base64,IMG_R) r", "key", "gpt-5", trunk_a.execution_id)
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: img_r)
    img_x, _ = @chat.add_user_message("![](data:image/png;base64,IMG_X) x", "key", "gpt-5", img_r.execution_id)
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: img_x)
    img_y, _ = @chat.add_user_message("![](data:image/png;base64,IMG_Y) y", "key", "gpt-5", img_x.execution_id)
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: img_y)
    img_z, _ = @chat.add_user_message("![](data:image/png;base64,IMG_Z) z", "key", "gpt-5", img_y.execution_id)
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: img_z)

    # New PE sent from img_z — walks back along its branch chain.
    next_pe = PromptNavigator::PromptExecution.new(prompt: "now", previous: img_z)
    result = @chat.send(:collect_recent_images, next_pe,
                        current_image: { mime: "image/png", data_b64: "CUR" })

    # HISTORICAL_IMAGE_LIMIT = 2 — keep the two CLOSEST to current (Y and Z),
    # not the oldest two (R and X). Trunk's image must not leak in.
    data = result.map { |i| i[:data_b64] }
    assert_equal [ "IMG_Y", "IMG_Z", "CUR" ], data
    refute_includes data, "IMG_R"
    refute_includes data, "IMG_X"
    refute_includes data, "TRUNK"
  end

  # ----- build_streaming_messages branch awareness ----- #

  test "build_streaming_messages includes only the branch's lineage, not sibling-branch turns" do
    # Trunk-A → Trunk-B (sibling branch off Trunk-A), and Trunk-A → Branch-C
    # (the branch we'll send from).
    trunk_a, _ = @chat.add_user_message("trunk-a question", "key", "gpt-5")
    trunk_a.update!(response: "trunk-a answer")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: trunk_a)

    trunk_b, _ = @chat.add_user_message("trunk-b sibling talk", "key", "gpt-5", trunk_a.execution_id)
    trunk_b.update!(response: "trunk-b answer")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: trunk_b)

    branch_c, _ = @chat.add_user_message("branch-c follow-up", "key", "gpt-5", trunk_a.execution_id)
    branch_c.update!(response: "branch-c answer")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: branch_c)

    # New prompt sent from the branch tip (branch_c). build_streaming_messages
    # should anchor on this PE and walk its `previous` chain — visiting
    # branch_c → trunk_a only, never trunk_b.
    next_pe, _ = @chat.add_user_message("next on branch", "key", "gpt-5", branch_c.execution_id)

    messages = nil
    with_stub(LlmMetaClient::ServerResource, :available_llm_options,
              [ { uuid: "key", llm_type: "openai" } ]) do
      messages, _ = @chat.send(:build_streaming_messages, next_pe, "jwt")
    end
    joined = messages.map { |m| m[:content] }.join("\n")

    # The branch's turns appear as role-tagged messages; the sibling's do not.
    assert_includes joined, "branch-c follow-up"
    assert_includes joined, "trunk-a question"
    refute_includes joined, "trunk-b sibling talk"
    refute_includes joined, "trunk-b answer"
  end

  # ----- summarization_target (private) ----- #

  test "summarization_target returns [ollama_uuid, SUMMARIZATION_MODEL] when ollama+the model are available" do
    options = [
      { uuid: "openai-key", llm_type: "openai", available_models: [ { "value" => "gpt-5" } ] },
      { uuid: "ollama-local", llm_type: "ollama", available_models: [
        { "value" => "qwen3-6-35b-fast" }, { "value" => "qwen3-6-35b" }
      ] }
    ]
    assert_equal [ "ollama-local", "qwen3-6-35b-fast" ],
                 @chat.send(:summarization_target, options)
  end

  test "summarization_target returns nil when ollama is missing from llm_options" do
    options = [ { uuid: "k", llm_type: "openai", available_models: [] } ]
    assert_nil @chat.send(:summarization_target, options)
  end

  test "summarization_target returns nil when ollama is present but SUMMARIZATION_MODEL is not in its catalog" do
    options = [ { uuid: "ollama-local", llm_type: "ollama", available_models: [
      { "value" => "qwen3-6-35b" }
    ] } ]
    assert_nil @chat.send(:summarization_target, options)
  end

  test "summarization_target accepts symbol-keyed model entries too" do
    options = [ { uuid: "ollama-local", llm_type: "ollama", available_models: [
      { value: "qwen3-6-35b-fast" }
    ] } ]
    assert_equal [ "ollama-local", "qwen3-6-35b-fast" ],
                 @chat.send(:summarization_target, options)
  end

  # ----- resolve_llm_type (private, hits ServerResource) ----- #

  test "resolve_llm_type looks up the llm_type for a given uuid via ServerResource" do
    with_stub(LlmMetaClient::ServerResource, :available_llm_options,
              [ { uuid: "k1", llm_type: "openai" },
                { uuid: "k2", llm_type: "anthropic" } ]) do
      assert_equal "anthropic", @chat.send(:resolve_llm_type, "k2", "jwt")
    end
  end

  test "resolve_llm_type returns 'unknown' when the uuid isn't in the options" do
    with_stub(LlmMetaClient::ServerResource, :available_llm_options, []) do
      assert_equal "unknown", @chat.send(:resolve_llm_type, "missing", "jwt")
    end
  end

  # ----- summarize_for_title — the "Undefined Image" bug regression guard ----- #

  test "summarize_for_title strips the leading image before calling the summarizer" do
    pe, _m = @chat.add_user_message("Describe", "key-1", "gpt-5", nil,
                                     image: { mime: "image/png", data_b64: "AAA" })
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: pe)

    captured_prompt_arg = nil
    fake_query = Object.new
    fake_query.define_singleton_method(:call) do |_jwt, _uuid, _model, _ctx, body|
      captured_prompt_arg = body[:prompt]
      "A short title"
    end

    with_stub(LlmMetaClient::ServerQuery, :new, fake_query) do
      result = @chat.send(:summarize_for_title, pe.prompt, "jwt")
      assert_equal "A short title", result
    end

    # The summarizer must NEVER see the image-markdown — that's how the
    # "Undefined Image" title used to leak in.
    refute_includes captured_prompt_arg.to_s, "data:image"
    refute_includes captured_prompt_arg.to_s, "base64"
    assert_includes captured_prompt_arg.to_s, "Describe"
  end

  test "summarize_for_title short-circuits to nil when the prompt is image-only (no text remains after strip)" do
    pe, _m = @chat.add_user_message("", "key-1", "gpt-5", nil,
                                     image: { mime: "image/png", data_b64: "AAA" })
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: pe)

    called = false
    fake_query = Object.new
    fake_query.define_singleton_method(:call) { |*| called = true; "x" }

    with_stub(LlmMetaClient::ServerQuery, :new, fake_query) do
      assert_nil @chat.send(:summarize_for_title, pe.prompt, "jwt")
    end
    refute called, "the summarizer must not be called for an image-only prompt"
  end

  test "summarize_for_title falls back to the truncated prompt when there are no user messages yet" do
    # Without a latest PE we can't dispatch to an LLM, but we still need to
    # return *something* so chat_manager's title filter doesn't hide the chat.
    fake_query = Object.new
    fake_query.define_singleton_method(:call) { |*| raise "should not be called" }
    with_stub(LlmMetaClient::ServerQuery, :new, fake_query) do
      assert_equal "some text", @chat.send(:summarize_for_title, "some text", "jwt")
    end
  end

  test "summarize_for_title falls back to the truncated prompt when the LLM returns blank" do
    # Medgemma in particular wraps its response inside <unused94>…<unused95>
    # sentinels; after stripping there's nothing left, which used to leave
    # the chat title blank — and chat_manager hides untitled chats from the
    # sidebar. Verified at the strip layer too.
    pe, _m = @chat.add_user_message("Diagnose this", "key-1", "medgemma1-5-4b")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: pe)

    fake_query = Object.new
    fake_query.define_singleton_method(:call) { |*| "<unused94>thought\nreasoning\n<unused95>" }

    with_stub(LlmMetaClient::ServerQuery, :new, fake_query) do
      assert_equal "Diagnose this", @chat.send(:summarize_for_title, pe.prompt, "jwt")
    end
  end

  test "summarize_for_title falls back to the truncated prompt when the LLM call raises" do
    pe, _m = @chat.add_user_message("Diagnose this", "key-1", "gpt-5")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: pe)

    fake_query = Object.new
    fake_query.define_singleton_method(:call) { |*| raise StandardError, "boom" }

    with_stub(LlmMetaClient::ServerQuery, :new, fake_query) do
      assert_equal "Diagnose this", @chat.send(:summarize_for_title, pe.prompt, "jwt")
    end
  end

  test "summarize_for_title routes through the cheap summarization_target when available (avoids user's thinking model)" do
    pe, _m = @chat.add_user_message("write a poem", "user-uuid", "gpt-5")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: pe)

    captured_uuid = nil
    captured_model = nil
    fake_query = Object.new
    fake_query.define_singleton_method(:call) do |_jwt, uuid, model, _ctx, _body|
      captured_uuid = uuid
      captured_model = model
      "Poem Request"
    end

    with_stub(LlmMetaClient::ServerResource, :available_llm_options, [ {
      uuid: "ollama-local",
      llm_type: "ollama",
      available_models: [ { "value" => "qwen3-5-4b" } ]
    } ]) do
      with_stub(Rails.configuration, :summarization_model, "qwen3-5-4b") do
        with_stub(LlmMetaClient::ServerQuery, :new, fake_query) do
          @chat.send(:summarize_for_title, "write a poem", "jwt")
        end
      end
    end

    # The summarizer should target the cheap Ollama model, NOT the user's gpt-5.
    assert_equal "ollama-local", captured_uuid
    assert_equal "qwen3-5-4b",   captured_model
  end

  test "strip_title_reasoning_preamble picks the last short line so reasoning preambles get discarded" do
    reasoning_response = "My Thought Process: The user wants a title.\nOkay, let me think.\nBreaking It Down"
    assert_equal "Breaking It Down", @chat.send(:strip_title_reasoning_preamble, reasoning_response)
  end

  test "strip_title_reasoning_preamble keeps the first line when the response is a single line" do
    assert_equal "A Clean Title", @chat.send(:strip_title_reasoning_preamble, "A Clean Title")
  end

  test "strip_title_reasoning_preamble caps at 100 chars so a wall-of-reasoning single line doesn't survive" do
    wall = "x" * 250
    out = @chat.send(:strip_title_reasoning_preamble, wall)
    assert_operator out.length, :<=, 100
  end

  test "strip_title_reasoning_preamble falls back to the first line when the last line is too long" do
    # Common shape from chatty models: short question up top, then a
    # multi-paragraph explanation. The last line is oversized (> 100 chars),
    # so we fall back to the first line instead.
    first_line = "Quick Summary"
    long_tail = "This is an extended piece of reasoning that goes on and on and on and on and on and on and clearly wouldn't fit as a chat title anywhere"
    out = @chat.send(:strip_title_reasoning_preamble, "#{first_line}\n\n#{long_tail}")
    assert_equal first_line, out
  end

  test "summarize_for_title falls back to the user's own PE model when summarization_target isn't available" do
    pe, _m = @chat.add_user_message("hello", "user-key-uuid", "gpt-5")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: pe)

    captured_uuid = nil
    captured_model = nil
    fake_query = Object.new
    fake_query.define_singleton_method(:call) do |_jwt, uuid, model, _ctx, _body|
      captured_uuid = uuid
      captured_model = model
      "Hello Title"
    end

    # No Ollama entry in the catalog → summarization_target returns nil →
    # the code should fall back to the user's own PE (uuid/model).
    with_stub(LlmMetaClient::ServerResource, :available_llm_options, []) do
      with_stub(LlmMetaClient::ServerQuery, :new, fake_query) do
        @chat.send(:summarize_for_title, "hello", "jwt")
      end
    end

    assert_equal "user-key-uuid", captured_uuid
    assert_equal "gpt-5",         captured_model
  end

  test "summarize_for_title strips markdown formatting from the LLM's reply" do
    pe, _m = @chat.add_user_message("Hello world", "key-1", "gpt-5")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: pe)

    fake_query = Object.new
    fake_query.define_singleton_method(:call) { |*| "**Greeting**" }

    with_stub(LlmMetaClient::ServerQuery, :new, fake_query) do
      assert_equal "Greeting", @chat.send(:summarize_for_title, pe.prompt, "jwt")
    end
  end

  # ----- strip_title_markdown (private) ----- #

  test "strip_title_markdown removes ** ** bold emphasis" do
    assert_equal "Greeting", @chat.send(:strip_title_markdown, "**Greeting**")
  end

  test "strip_title_markdown removes * * italic emphasis" do
    assert_equal "Greeting", @chat.send(:strip_title_markdown, "*Greeting*")
  end

  test "strip_title_markdown removes __ __ and _ _ underscore emphasis" do
    assert_equal "Greeting", @chat.send(:strip_title_markdown, "__Greeting__")
    assert_equal "Greeting", @chat.send(:strip_title_markdown, "_Greeting_")
  end

  test "strip_title_markdown removes inline `code` backticks" do
    assert_equal "Run bin/dev", @chat.send(:strip_title_markdown, "Run `bin/dev`")
  end

  test "strip_title_markdown removes a leading # heading marker" do
    assert_equal "My title", @chat.send(:strip_title_markdown, "# My title")
    assert_equal "Sub title", @chat.send(:strip_title_markdown, "### Sub title")
  end

  test "strip_title_markdown strips wrapping straight and curly quotes" do
    assert_equal "Hello", @chat.send(:strip_title_markdown, '"Hello"')
    assert_equal "Hello", @chat.send(:strip_title_markdown, "'Hello'")
    assert_equal "Hello", @chat.send(:strip_title_markdown, "“Hello”")
    assert_equal "Hello", @chat.send(:strip_title_markdown, "「Hello」")
  end

  test "strip_title_markdown returns plain text untouched" do
    assert_equal "A simple title", @chat.send(:strip_title_markdown, "A simple title")
  end

  test "strip_title_markdown returns empty string for nil and empty input (does not raise)" do
    assert_equal "", @chat.send(:strip_title_markdown, nil)
    assert_equal "", @chat.send(:strip_title_markdown, "")
  end

  test "strip_title_markdown drops Gemma <unused94>...<unused95> reasoning blocks" do
    raw = "<unused94>thought\nHere's a thinking process for analyzing the chest X-ray.\n<unused95>Chest X-ray findings"
    assert_equal "Chest X-ray findings", @chat.send(:strip_title_markdown, raw)
  end

  test "strip_title_markdown removes orphaned <unusedNN> tokens when the close sentinel is missing" do
    assert_equal "Some title", @chat.send(:strip_title_markdown, "<unused94>Some title")
    assert_equal "Title", @chat.send(:strip_title_markdown, "<unused42>Title")
  end

  # ----- finalize_streamed_response ----- #

  test "finalize_streamed_response skips persistence when content is blank" do
    pe, _m = @chat.add_user_message("hi", "k", "gpt-5")

    assert_no_difference -> { @chat.messages.count } do
      assert_nil @chat.finalize_streamed_response(pe, "", "jwt")
      assert_nil @chat.finalize_streamed_response(pe, nil, "jwt")
    end
  end

  test "finalize_streamed_response persists the content + creates an assistant message when content present" do
    pe, _m = @chat.add_user_message("hi", "k", "gpt-5", nil, llm_platform: "openai")

    with_stub(LlmMetaClient::ServerResource, :available_llm_options, [ { uuid: "k", llm_type: "openai" } ]) do
      assert_difference -> { @chat.messages.where(role: "assistant").count }, 1 do
        msg = @chat.finalize_streamed_response(pe, "the response", "jwt")
        assert msg.persisted?
        assert_equal "assistant", msg.role
      end
    end

    assert_equal "the response", pe.reload.response
    # llm_platform was already set on the PE; it must not be overwritten.
    assert_equal "openai", pe.llm_platform
  end

  test "finalize_streamed_response resolves llm_platform from llm_uuid when the PE has none yet" do
    pe = PromptNavigator::PromptExecution.create!(
      prompt: "hi", llm_uuid: "key-1", model: "gpt-5",
      llm_platform: nil, configuration: ""
    )
    @chat.messages.create!(role: "user", prompt_navigator_prompt_execution: pe)

    with_stub(LlmMetaClient::ServerResource, :available_llm_options,
              [ { uuid: "key-1", llm_type: "openai" } ]) do
      @chat.finalize_streamed_response(pe, "r", "jwt")
    end

    assert_equal "openai", pe.reload.llm_platform
  end

  test "finalize_streamed_response is idempotent: second call with the same PE returns the existing message and creates no duplicate" do
    pe = PromptNavigator::PromptExecution.create!(prompt: "p", llm_platform: "openai", configuration: "")
    @chat.messages.create!(role: "user", prompt_navigator_prompt_execution: pe)

    first  = @chat.finalize_streamed_response(pe, "response text", "jwt")
    second = @chat.finalize_streamed_response(pe, "response text", "jwt")

    assert_equal first.id, second.id
    assert_equal 1, @chat.messages.where(role: "assistant", prompt_navigator_prompt_execution_id: pe.id).count
  end

  # ----- build_streaming_context (private — token-budget decisions) ----- #

  # Builds a linear chain of N user→assistant turns on the chat, returning the
  # last (most-recent) PE. Each turn's prompt/response are "p<i>" / "r<i>".
  def build_chain(n, model: "gpt-5", llm_uuid: "key-1")
    last_pe = nil
    n.times do |i|
      pe = PromptNavigator::PromptExecution.create!(
        prompt: "p#{i + 1}", response: "r#{i + 1}",
        llm_uuid: llm_uuid, model: model, configuration: "", previous_id: last_pe&.id
      )
      @chat.messages.create!(role: "user", prompt_navigator_prompt_execution: pe)
      @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: pe)
      last_pe = pe
    end
    last_pe
  end

  # Helper to pin verbatim_count for a single test (default is 10).
  def with_verbatim_count(n)
    original = Rails.configuration.summarize_conversation_count
    Rails.configuration.summarize_conversation_count = n
    yield
  ensure
    Rails.configuration.summarize_conversation_count = original
  end

  test "build_streaming_messages raises OllamaUnavailableError when no LLM options are configured" do
    pe = build_chain(1)
    with_stub(LlmMetaClient::ServerResource, :available_llm_options, []) do
      assert_raises(LlmMetaClient::Exceptions::OllamaUnavailableError) do
        @chat.send(:build_streaming_messages, pe, "jwt")
      end
    end
  end

  test "build_streaming_messages returns an empty messages array for image-gen models" do
    pe = build_chain(5, model: "gemini-3-pro-image")
    with_stub(LlmMetaClient::ServerResource, :available_llm_options,
              [ { uuid: "k", llm_type: "openai" } ]) do
      messages, current = @chat.send(:build_streaming_messages, pe, "jwt")
      assert_equal [], messages
      # Current-turn text is still returned as the second tuple element.
      assert_equal "p5", current
    end
  end

  test "build_streaming_messages emits only a system directive (no prior turns) for a root prompt with no ancestors" do
    pe = build_chain(1)
    with_stub(LlmMetaClient::ServerResource, :available_llm_options,
              [ { uuid: "k", llm_type: "openai" } ]) do
      messages, _ = @chat.send(:build_streaming_messages, pe, "jwt")

      assert_equal 1, messages.length
      assert_equal "system", messages.first[:role]
      assert_includes messages.first[:content], "Responses from the assistant must consist solely of the response body."
    end
  end

  test "build_streaming_messages replays ancestors as role-tagged messages when chain length <= verbatim_count" do
    # 3 turns, verbatim_count = 5 → all ancestors replayed verbatim, no summarize call.
    pe = build_chain(3)
    called_summarize = false
    fake_query = Object.new
    fake_query.define_singleton_method(:call) { |*| called_summarize = true; "x" }

    with_verbatim_count(5) do
      with_stub(LlmMetaClient::ServerResource, :available_llm_options,
                [ { uuid: "k", llm_type: "openai" } ]) do
        with_stub(LlmMetaClient::ServerQuery, :new, fake_query) do
          messages, _ = @chat.send(:build_streaming_messages, pe, "jwt")

          # Expect: [system, user p1, assistant r1, user p2, assistant r2, user p3, assistant r3]
          # (p3 IS included as an ancestor entry too because build_chain
          # creates PEs that link back to their previous; the leaf is
          # itself part of the walked chain.)
          roles = messages.map { |m| m[:role] }
          assert_equal "system", roles.first
          # Ancestor content lands as separate role-tagged messages —
          # NOT concatenated into a "User: ...\nAssistant: ..." string.
          user_contents = messages.select { |m| m[:role] == "user" }.map { |m| m[:content] }
          asst_contents = messages.select { |m| m[:role] == "assistant" }.map { |m| m[:content] }
          assert_includes user_contents, "p1"
          assert_includes user_contents, "p2"
          assert_includes asst_contents, "r1"
          assert_includes asst_contents, "r2"
          # No summary marker.
          refute(messages.any? { |m| m[:content].to_s.include?("Summary of earlier conversation") })
        end
      end
    end
    refute called_summarize, "the summarizer must not be invoked within budget"
  end

  test "build_streaming_messages summarizes the older slice into a system message and keeps recent turns as messages" do
    # 8 turns total, verbatim_count = 3 → older = 4 ancestors get summarized;
    # recent 3 kept verbatim as role-tagged messages.
    pe = build_chain(8)
    captured = nil
    fake_query = Object.new
    fake_query.define_singleton_method(:call) do |_jwt, _uuid, _model, ctx, _body|
      captured = ctx
      "older-summary"
    end

    with_verbatim_count(3) do
      with_stub(LlmMetaClient::ServerResource, :available_llm_options,
                [ { uuid: "k", llm_type: "openai" } ]) do
        with_stub(LlmMetaClient::ServerQuery, :new, fake_query) do
          messages, _ = @chat.send(:build_streaming_messages, pe, "jwt")

          # System message carries the summary + the always-on directive.
          system_msg = messages.find { |m| m[:role] == "system" }
          assert_not_nil system_msg
          assert_includes system_msg[:content], "Summary of earlier conversation: older-summary"
          assert_includes system_msg[:content], "Responses from the assistant must consist solely of the response body."

          # Recent 3 of the 7 ancestors are p5..p7 (p8 is the active turn).
          user_contents = messages.select { |m| m[:role] == "user" }.map { |m| m[:content] }
          asst_contents = messages.select { |m| m[:role] == "assistant" }.map { |m| m[:content] }
          %w[p5 p6 p7].each { |p| assert_includes user_contents, p }
          %w[r5 r6 r7].each { |r| assert_includes asst_contents, r }
          # Older turns must NOT reappear as their own role-tagged messages.
          %w[p1 p2 p3 p4].each { |p| refute_includes user_contents, p }
        end
      end
    end

    # The summarizer received the older slice as its context arg.
    assert captured.is_a?(Array)
    assert_equal [ "p1", "p2", "p3", "p4" ], captured.map { |t| t[:prompt] }
  end

  test "build_streaming_messages prefers the ollama qwen summarizer when available" do
    pe = build_chain(8)
    summarizer_uuid = summarizer_model = nil
    fake_query = Object.new
    fake_query.define_singleton_method(:call) do |_jwt, uuid, model, _ctx, _body|
      summarizer_uuid = uuid
      summarizer_model = model
      "summary"
    end

    options = [
      { uuid: "key-1", llm_type: "openai", available_models: [ { "value" => "gpt-5" } ] },
      { uuid: "ollama-local", llm_type: "ollama", available_models: [
        { "value" => "qwen3-6-35b-fast" }, { "value" => "qwen3-6-35b" }
      ] }
    ]

    with_verbatim_count(3) do
      with_stub(LlmMetaClient::ServerResource, :available_llm_options, options) do
        with_stub(LlmMetaClient::ServerQuery, :new, fake_query) do
          @chat.send(:build_streaming_messages, pe, "jwt")
        end
      end
    end

    assert_equal "ollama-local", summarizer_uuid
    assert_equal "qwen3-6-35b-fast", summarizer_model
  end

  test "build_streaming_messages falls back to the user's own model when ollama qwen isn't available" do
    pe = build_chain(8)
    summarizer_uuid = summarizer_model = nil
    fake_query = Object.new
    fake_query.define_singleton_method(:call) do |_jwt, uuid, model, _ctx, _body|
      summarizer_uuid = uuid
      summarizer_model = model
      "summary"
    end

    # No ollama in the options at all → summarization_target returns nil.
    options = [ { uuid: "key-1", llm_type: "openai", available_models: [] } ]

    with_verbatim_count(3) do
      with_stub(LlmMetaClient::ServerResource, :available_llm_options, options) do
        with_stub(LlmMetaClient::ServerQuery, :new, fake_query) do
          @chat.send(:build_streaming_messages, pe, "jwt")
        end
      end
    end

    assert_equal "key-1", summarizer_uuid
    assert_equal "gpt-5", summarizer_model
  end

  test "build_streaming_messages appends the tool-error directive to the system message only when with_tools: true" do
    pe = build_chain(1)
    with_stub(LlmMetaClient::ServerResource, :available_llm_options,
              [ { uuid: "k", llm_type: "openai" } ]) do
      messages_no_tools, _ = @chat.send(:build_streaming_messages, pe, "jwt", with_tools: false)
      messages_tools,    _ = @chat.send(:build_streaming_messages, pe, "jwt", with_tools: true)

      sys_no_tools = messages_no_tools.find { |m| m[:role] == "system" }[:content]
      sys_tools    = messages_tools.find { |m| m[:role] == "system" }[:content]

      refute_includes sys_no_tools, "tool call returns an error"
      assert_includes sys_tools,    "tool call returns an error"
      # Both still carry the always-on directive.
      assert_includes sys_no_tools, "Responses from the assistant must consist solely of the response body."
      assert_includes sys_tools,    "Responses from the assistant must consist solely of the response body."
    end
  end

  test "build_streaming_messages strips inline data-URI attachments from historical turns" do
    # Turn 1 had an image attached; the raw data URI should NOT resurface as
    # base64 in the messages array (would balloon context tokens).
    pe1 = PromptNavigator::PromptExecution.create!(
      prompt: "![](data:image/png;base64,BASE64BLOB) what is this?",
      response: "An apple.",
      llm_uuid: "k", model: "gpt-5", configuration: ""
    )
    @chat.messages.create!(role: "user",      prompt_navigator_prompt_execution: pe1)
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: pe1)
    pe2 = PromptNavigator::PromptExecution.create!(
      prompt: "and the color?", response: "",
      llm_uuid: "k", model: "gpt-5", configuration: "",
      previous_id: pe1.id
    )
    @chat.messages.create!(role: "user", prompt_navigator_prompt_execution: pe2)

    with_verbatim_count(10) do
      with_stub(LlmMetaClient::ServerResource, :available_llm_options,
                [ { uuid: "k", llm_type: "openai" } ]) do
        messages, _ = @chat.send(:build_streaming_messages, pe2, "jwt")
        joined = messages.map { |m| m[:content] }.join("\n")
        refute_includes joined, "BASE64BLOB"
        assert_includes joined, "[image] what is this?"
      end
    end
  end

  # ----- messages touch: true (activity floats chat in sidebar) ----- #
  # Message#belongs_to :chat has touch: true so User.chats (ordered by
  # updated_at) reflects real activity, not just rename events. Guards
  # against accidental removal of the touch: option — without it, chats
  # would only float on title changes, defeating the sidebar UX.
  test "creating a message bumps the chat's updated_at (touch: true)" do
    pe = PromptNavigator::PromptExecution.create!(
      prompt: "hi", response: "hello", llm_uuid: "k", model: "gpt-5", configuration: ""
    )
    original_updated_at = @chat.updated_at
    travel_to(1.hour.from_now) do
      @chat.messages.create!(role: "user", prompt_navigator_prompt_execution: pe)
    end
    assert_operator @chat.reload.updated_at, :>, original_updated_at
  end

  # Composed user-facing story: create chats → add a message to the older
  # one → that chat floats to the top of the sidebar list. Guards against
  # either piece (User.has_many order OR Message#belongs_to touch:) silently
  # regressing without breaking its individual test. This is the exact bug
  # the two-part fix was meant to prevent.
  test "adding a message bumps that chat to the top of user.chats (integration)" do
    user = User.create!(email: "int@example.com", google_id: "g-int", id_token: "t")
    older = user.chats.create!(title: "older")
    newer = user.chats.create!(title: "newer")
    # `newer` is currently newest by updated_at. Add a message to `older`
    # and it should float above `newer`.
    pe = PromptNavigator::PromptExecution.create!(
      prompt: "hi", response: "", llm_uuid: "k", model: "gpt-5", configuration: ""
    )
    travel_to(1.hour.from_now) do
      older.messages.create!(role: "user", prompt_navigator_prompt_execution: pe)
    end
    # user.chats is ordered ASC by updated_at; the sidebar's .reverse then
    # renders newest first. So the LAST element in ASC order == the TOP of
    # the sidebar after reverse.
    assert_equal older.uuid, user.chats.reload.map(&:uuid).last
  end
end
