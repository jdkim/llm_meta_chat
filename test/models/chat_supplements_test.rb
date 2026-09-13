require "test_helper"

# Supplement nodes: a prompt may cite other executions in the same chat, whose
# content is attached to that turn as reference material.
#
# The tree is untouched — `previous_id` is still exactly one parent. What needs
# pinning here is the chat scoping (an unscoped id would read another
# conversation's content into this one), the persistence order, and the shape
# of the injected block, since that block is what the user's prompt refers to
# in words.
class ChatSupplementsTest < ActiveSupport::TestCase
  setup do
    @chat  = Chat.create!(uuid: SecureRandom.uuid)
    @other = Chat.create!(uuid: SecureRandom.uuid)
  end

  def pe_in(chat, prompt:, response: "r", model: nil)
    pe = PromptNavigator::PromptExecution.create!(prompt: prompt, response: response, model: model)
    chat.messages.create!(role: "user", prompt_navigator_prompt_execution: pe)
    pe
  end

  # ----- resolve_supplements! -----

  test "resolves ids belonging to this chat, preserving the order given" do
    a = pe_in(@chat, prompt: "a")
    b = pe_in(@chat, prompt: "b")

    resolved = @chat.resolve_supplements!([ b.execution_id, a.execution_id ])

    assert_equal [ b.id, a.id ], resolved.map(&:id)
  end

  # The security property. `resolve_parent!` is strict about this for the same
  # reason: the tree walks `previous` with no chat boundary, so an id from
  # another chat would pull a stranger's content into this context.
  test "silently drops ids belonging to another chat" do
    mine    = pe_in(@chat,  prompt: "mine")
    theirs  = pe_in(@other, prompt: "theirs")

    resolved = @chat.resolve_supplements!([ mine.execution_id, theirs.execution_id ])

    assert_equal [ mine.id ], resolved.map(&:id)
  end

  test "drops unknown ids rather than raising" do
    a = pe_in(@chat, prompt: "a")

    assert_equal [ a.id ], @chat.resolve_supplements!([ a.execution_id, "not-a-real-node" ]).map(&:id)
  end

  test "de-duplicates repeated ids" do
    a = pe_in(@chat, prompt: "a")

    assert_equal [ a.id ], @chat.resolve_supplements!([ a.execution_id, a.execution_id ]).map(&:id)
  end

  test "returns nothing for blank input" do
    assert_empty @chat.resolve_supplements!(nil)
    assert_empty @chat.resolve_supplements!([ "", nil ])
  end

  # The cap is the only guard on a turn's cost, which is otherwise entirely
  # user-controlled — so exceeding it is an error, not a silent truncation.
  test "refuses more than the cap" do
    ids = (Chat::MAX_SUPPLEMENTS + 1).times.map { |i| pe_in(@chat, prompt: "p#{i}").execution_id }

    assert_raises Chat::InvalidParentError do
      @chat.resolve_supplements!(ids)
    end
  end

  test "accepts exactly the cap" do
    ids = Chat::MAX_SUPPLEMENTS.times.map { |i| pe_in(@chat, prompt: "p#{i}").execution_id }

    assert_equal Chat::MAX_SUPPLEMENTS, @chat.resolve_supplements!(ids).length
  end

  # ----- persistence -----

  test "add_user_message records the citations in the order given" do
    a = pe_in(@chat, prompt: "a")
    b = pe_in(@chat, prompt: "b")

    pe, _msg = @chat.add_user_message("compare", "uuid", "model", previous_id: nil, supplements: [ b, a ])

    assert_equal [ b.id, a.id ], pe.reload.supplements.map(&:id)
  end

  # The stored prompt must stay what the user typed. Folding the block in would
  # make the history card render a wall of pasted text, and regenerating the
  # turn would double it.
  test "the reference block is not written into the stored prompt" do
    a = pe_in(@chat, prompt: "a", response: "a distinctive answer")

    pe, _msg = @chat.add_user_message("compare", "uuid", "model", previous_id: nil, supplements: [ a ])

    assert_equal "compare", pe.reload.prompt
    assert_not_includes pe.prompt, "a distinctive answer"
  end

  test "a prompt with no citations records no edges" do
    pe, _msg = @chat.add_user_message("plain", "uuid", "model", previous_id: nil)

    assert_empty pe.reload.supplements
  end

  # ----- injected block -----

  def block_for(target, text = "the question")
    @chat.send(:prepend_reference_block, target.reload, text)
  end

  test "identical prompts render once, with one labelled answer per model" do
    q = "Which treatment?"
    a = pe_in(@chat, prompt: q, response: "Answer A.", model: "claude-fable-5-1")
    b = pe_in(@chat, prompt: q, response: "Answer B.", model: "gpt-5.6-terra")
    target, = @chat.add_user_message("compare", "u", "m", previous_id: nil, supplements: [ a, b ])

    block = block_for(target)

    assert_equal 1, block.scan("Question: #{q}").length, "the shared question should appear once"
    assert_includes block, "[1] claude-fable-5-1 — Answer A."
    assert_includes block, "[2] gpt-5.6-terra — Answer B."
    assert_includes block, "The same question was put to several models."
  end

  test "a lone citation gets no same-question framing" do
    a = pe_in(@chat, prompt: "just one", response: "r", model: "m")
    target, = @chat.add_user_message("go", "u", "m", previous_id: nil, supplements: [ a ])

    block = block_for(target)

    assert_includes block, "Question: just one"
    assert_not_includes block, "The same question was put to several models."
  end

  # Numbering runs across groups so a prompt can say "reference 3" and have it
  # mean something.
  test "labels are numbered continuously across groups" do
    q = "shared"
    a = pe_in(@chat, prompt: q, response: "A", model: "m1")
    b = pe_in(@chat, prompt: q, response: "B", model: "m2")
    c = pe_in(@chat, prompt: "different", response: "C", model: "m3")
    target, = @chat.add_user_message("go", "u", "m", previous_id: nil, supplements: [ a, b, c ])

    block = block_for(target)

    assert_includes block, "[1] m1 — A"
    assert_includes block, "[2] m2 — B"
    assert_includes block, "[3] m3 — C"
  end

  test "the user's own text follows the block, intact and multi-line" do
    a = pe_in(@chat, prompt: "a", response: "r", model: "m")
    target, = @chat.add_user_message("go", "u", "m", previous_id: nil, supplements: [ a ])

    block = block_for(target, "First line.\nSecond line.")

    assert_includes block, "First line.\nSecond line."
    assert block.index("End of referenced material") < block.index("First line."),
           "the user's text must come after the referenced material"
  end

  test "a citation with no model falls back to a usable label" do
    a = pe_in(@chat, prompt: "a", response: "r", model: nil)
    target, = @chat.add_user_message("go", "u", "m", previous_id: nil, supplements: [ a ])

    assert_includes block_for(target), "[1] unknown model — r"
  end

  # Referenced answers can themselves contain data-URI attachments; re-sending
  # tens of KB of base64 per citation would be the expensive kind of silent.
  test "inline attachments in cited content are stripped" do
    a = pe_in(@chat, prompt: "a", response: "![](data:image/png;base64,AAAA) see this", model: "m")
    target, = @chat.add_user_message("go", "u", "m", previous_id: nil, supplements: [ a ])

    block = block_for(target)

    assert_not_includes block, "base64"
    assert_includes block, "[image]"
  end

  test "a prompt with no citations gets no block at all" do
    target, = @chat.add_user_message("plain", "u", "m", previous_id: nil)

    assert_equal "the question", block_for(target)
  end

  # ----- the wiring, not just the pieces -----
  #
  # Everything above exercises prepend_reference_block directly. That left the
  # one line that actually calls it on the send path untested: deleting it
  # disabled the entire feature and the whole suite still passed. These drive
  # build_streaming_messages, which is what the streaming controller calls.

  def with_llm_options(&block)
    with_stub(LlmMetaClient::ServerResource, :available_llm_options,
              [ { uuid: "k", llm_type: "openai" } ], &block)
  end

  test "the block reaches the current turn that build_streaming_messages produces" do
    cited = pe_in(@chat, prompt: "what is aibranch?", response: "A branching chat UI.", model: "qwen3-8-27b")
    target, = @chat.add_user_message("compare", "k", "gpt-5", previous_id: nil, supplements: [ cited ])

    with_llm_options do
      _messages, current_text = @chat.send(:build_streaming_messages, target.reload, "jwt")

      assert_includes current_text, "Referenced material"
      assert_includes current_text, "[1] qwen3-8-27b — A branching chat UI."
      assert_includes current_text, "compare"
    end
  end

  # The material is attached to the current turn, deliberately not to the
  # system prompt (that channel is operating instructions) and not as prior
  # turns (the dialogue channel wire format v2 cleared).
  test "the block goes to the current turn, not into the messages array" do
    cited = pe_in(@chat, prompt: "q", response: "a distinctive answer", model: "m")
    target, = @chat.add_user_message("go", "k", "gpt-5", previous_id: nil, supplements: [ cited ])

    with_llm_options do
      messages, _current = @chat.send(:build_streaming_messages, target.reload, "jwt")

      assert_not(messages.any? { |m| m[:content].to_s.include?("a distinctive answer") },
                 "referenced material must not appear in the role-tagged messages")
    end
  end

  test "a turn with no citations gets no block on the send path" do
    target, = @chat.add_user_message("plain", "k", "gpt-5", previous_id: nil)

    with_llm_options do
      _messages, current_text = @chat.send(:build_streaming_messages, target.reload, "jwt")

      assert_equal "plain", current_text
    end
  end

  # Regenerating a turn re-runs this method against the same execution. The
  # block is rebuilt from the edges each time rather than stored, so it must
  # not accumulate.
  test "rebuilding the same turn does not duplicate the block" do
    cited = pe_in(@chat, prompt: "q", response: "r", model: "m")
    target, = @chat.add_user_message("go", "k", "gpt-5", previous_id: nil, supplements: [ cited ])

    with_llm_options do
      2.times { @chat.send(:build_streaming_messages, target.reload, "jwt") }
      _messages, current_text = @chat.send(:build_streaming_messages, target.reload, "jwt")

      assert_equal 1, current_text.scan("Referenced material").length
    end
  end

  # Chat deletion destroys messages; the executions and their edges outlive it.
  # Worth pinning because supplement edges are a foreign key into the
  # executions table, and an ordering mistake here would surface as an opaque
  # FK violation on a perfectly ordinary "delete chat".
  test "deleting a chat whose prompts cited each other does not raise" do
    a = pe_in(@chat, prompt: "a", response: "r")
    target, = @chat.add_user_message("cites a", "k", "gpt-5", previous_id: nil, supplements: [ a ])
    assert_equal [ a.id ], target.reload.supplements.map(&:id)

    assert_nothing_raised { @chat.destroy }
  end
end
