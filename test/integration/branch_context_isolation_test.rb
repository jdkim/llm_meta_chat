# Proposed for: llm_meta_chat/test/integration/branch_context_isolation_test.rb
#
# Dedicated test file for the branch-history and context-isolation guarantees
# described in Section 2 of the SoftwareX manuscript and cited in the response
# to reviewer 2 (comment R2-2). The file exists as a reviewer-visible entry
# point: a reader following the response letter's pointer at
# "test suite for branch-history and context isolation" should be able to
# open this file and see, in one place, the guarantees the system claims to
# uphold and the tests that pin them.
#
# Guarantees under test:
#
#   G1. Forking a conversation from a past turn creates a sibling branch;
#       the parent and the pre-existing branch (if any) are unmodified.
#
#   G2. When building the context to send to the model for a turn on branch B,
#       only turns on B's ancestor chain are included; turns from sibling
#       branches are excluded.
#
#   G3. Multi-level branching produces correct ancestry: forking a branch
#       of a branch of ... yields a chain that walks back through the
#       expected forks, not through the ancestors of unrelated siblings.
#
#   G4. Branching from an interior turn (not just the root) works: the new
#       branch inherits ancestor turns up to (and including) the fork point,
#       and starts diverging from the next turn.
#
#   G5. A branch created but never continued (empty branch) is well-formed
#       and does not affect any other branch's context.
#
#   G6. Deleting a leaf turn on one branch does not affect the ancestors
#       shared with siblings, and does not affect sibling branches at all.
#
# Some of these guarantees are also tested in llm_meta_chat/test/models/chat_test.rb,
# where they are interleaved with other Chat-model concerns. This file
# collects them under one topic and adds tests for guarantees (G3, G5, G6)
# that are not covered elsewhere.

require "test_helper"

class BranchContextIsolationTest < ActiveSupport::TestCase
  setup do
    @chat = Chat.create!
  end

  # ============================================================
  # G1 — Fork creates a sibling; parent + siblings unmodified
  # ============================================================

  test "G1: forking from a past turn creates a sibling branch that shares the parent's previous_id" do
    root, _  = @chat.add_user_message("root", "k", "gpt-5")
    child_a, _ = @chat.add_user_message("child-a", "k", "gpt-5")
    # Both siblings fork from `root`.
    child_b, _ = @chat.add_user_message("child-b sibling", "k", "gpt-5", root.execution_id)

    assert_equal root.id, child_a.previous_id, "child-a chains off root"
    assert_equal root.id, child_b.previous_id, "child-b also chains off root (sibling of child-a)"
    refute_equal child_a.id, child_b.previous_id, "child-b must NOT chain off child-a"
  end

  test "G1: forking does not mutate the parent turn or the pre-existing sibling" do
    root, _ = @chat.add_user_message("root", "k", "gpt-5")
    child_a, _ = @chat.add_user_message("child-a", "k", "gpt-5")

    # Reload before capturing baseline: in-memory attributes hold ns-precision
    # timestamps, but PG columns are µs-precision — post-reload comparisons
    # would otherwise fail on the sub-microsecond truncation alone.
    root_before   = root.reload.attributes.dup
    child_a_before = child_a.reload.attributes.dup

    # Fork off root.
    @chat.add_user_message("child-b", "k", "gpt-5", root.execution_id)

    assert_equal root_before,   root.reload.attributes,   "root turn must be unchanged"
    assert_equal child_a_before, child_a.reload.attributes, "pre-existing sibling must be unchanged"
  end

  # ============================================================
  # G2 — Context replay for branch B includes only B's ancestor chain
  # ============================================================

  test "G2: build_streaming_messages includes only the branch's lineage, not sibling turns" do
    # Structure:
    #     root
    #     ├── sibling-A
    #     └── sibling-B ── follow-up   (send-from is here)
    root, _ = @chat.add_user_message("root question", "k", "gpt-5")
    root.update!(response: "root answer")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: root)

    sibling_a, _ = @chat.add_user_message("sibling-a", "k", "gpt-5", root.execution_id)
    sibling_a.update!(response: "sibling-a answer")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: sibling_a)

    sibling_b, _ = @chat.add_user_message("sibling-b", "k", "gpt-5", root.execution_id)
    sibling_b.update!(response: "sibling-b answer")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: sibling_b)

    # New turn on sibling_b's branch.
    followup, _ = @chat.add_user_message("follow-up on b", "k", "gpt-5", sibling_b.execution_id)

    messages = nil
    with_stub(LlmMetaClient::ServerResource, :available_llm_options,
              [ { uuid: "k", llm_type: "openai" } ]) do
      messages, _ = @chat.send(:build_streaming_messages, followup, "jwt")
    end
    joined = messages.map { |m| m[:content] }.join("\n")

    # sibling_b's chain: root → sibling_b → follow-up.
    assert_includes joined, "root question",   "root ancestor must be present"
    assert_includes joined, "sibling-b",       "the branch's parent turn must be present"
    refute_includes joined, "sibling-a",       "the sibling branch's turn must NOT leak in"
    refute_includes joined, "sibling-a answer", "the sibling branch's response must NOT leak in"
  end

  # ============================================================
  # G3 — Multi-level branching yields correct ancestry
  # ============================================================

  test "G3: a branch of a branch walks back through its own fork points" do
    # Structure:
    #     root ── level1 ── level2 ── level3
    #                          └── level2-alt  (branch off level1)
    #                                 └── level3-alt  (branch off level2-alt)
    root, _   = @chat.add_user_message("root", "k", "gpt-5")
    root.update!(response: "root ans")
    l1, _     = @chat.add_user_message("level-1", "k", "gpt-5")
    l1.update!(response: "l1 ans")
    l2, _     = @chat.add_user_message("level-2", "k", "gpt-5")
    l2.update!(response: "l2 ans")
    l3, _     = @chat.add_user_message("level-3", "k", "gpt-5")
    l3.update!(response: "l3 ans")

    l2_alt, _ = @chat.add_user_message("level-2-alt", "k", "gpt-5", l1.execution_id)
    l2_alt.update!(response: "l2-alt ans")

    l3_alt, _ = @chat.add_user_message("level-3-alt", "k", "gpt-5", l2_alt.execution_id)
    l3_alt.update!(response: "l3-alt ans")

    # Walk l3_alt's ancestor chain via previous_id.
    ancestors = []
    node = l3_alt
    while node.previous_id
      node = PromptNavigator::PromptExecution.find(node.previous_id)
      ancestors.unshift(node.prompt)
    end

    assert_equal [ "root", "level-1", "level-2-alt" ], ancestors,
      "l3_alt's ancestry must include root, l1, l2_alt — NOT l2 or l3 from the main chain"
    refute_includes ancestors, "level-2", "main-chain l2 must NOT appear in l3_alt's ancestry"
    refute_includes ancestors, "level-3", "main-chain l3 must NOT appear in l3_alt's ancestry"
  end

  # ============================================================
  # G4 — Branching from an interior turn works
  # ============================================================

  test "G4: forking from an interior turn (not the root) preserves ancestors up to and including the fork point" do
    root, _ = @chat.add_user_message("root", "k", "gpt-5")
    mid, _  = @chat.add_user_message("mid", "k", "gpt-5")
    tip, _  = @chat.add_user_message("tip", "k", "gpt-5")

    # Fork off `mid` (the interior turn), NOT off root and NOT off tip.
    branch, _ = @chat.add_user_message("branch-off-mid", "k", "gpt-5", mid.execution_id)

    assert_equal mid.id, branch.previous_id,
      "branch must point at mid, not root and not tip"

    # Walk back — expect root → mid → branch.
    ancestors = []
    node = branch
    while node.previous_id
      node = PromptNavigator::PromptExecution.find(node.previous_id)
      ancestors.unshift(node.prompt)
    end
    assert_equal [ "root", "mid" ], ancestors,
      "branch's ancestor chain must include root and mid (the fork point), NOT tip"
    refute_includes ancestors, "tip", "the turn AFTER the fork point must not appear"
  end

  # ============================================================
  # G5 — An empty branch is well-formed and does not affect others
  # ============================================================

  test "G5: an empty branch (created but never continued) does not appear in any other branch's context" do
    root, _  = @chat.add_user_message("root", "k", "gpt-5")
    root.update!(response: "root ans")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: root)

    # Create an empty branch — a user PE without a response and without any
    # descendant turns.
    empty_branch, _ = @chat.add_user_message("empty-branch prompt", "k", "gpt-5", root.execution_id)

    # Continue on the main chain.
    followup, _ = @chat.add_user_message("main followup", "k", "gpt-5", root.execution_id)

    # The main-chain followup's context must not include the empty branch's prompt.
    messages = nil
    with_stub(LlmMetaClient::ServerResource, :available_llm_options,
              [ { uuid: "k", llm_type: "openai" } ]) do
      messages, _ = @chat.send(:build_streaming_messages, followup, "jwt")
    end
    joined = messages.map { |m| m[:content] }.join("\n")

    assert_includes joined, "root", "root ancestor must be present"
    refute_includes joined, "empty-branch prompt",
      "the empty branch on the sibling must NOT leak into main's context"
    refute_nil empty_branch.reload, "the empty branch itself must remain well-formed and persistent"
  end

  # ============================================================
  # G6 — Deleting a leaf does not affect ancestors or siblings
  # ============================================================

  # Helper: destroy a leaf PromptExecution the way the app does — Messages
  # referencing it via FK are removed first, then the PE itself.
  def destroy_leaf(pe)
    Message.where(prompt_navigator_prompt_execution_id: pe.id).destroy_all
    pe.destroy!
  end

  test "G6: deleting a leaf turn on one branch does not touch ancestors shared with siblings" do
    root, _  = @chat.add_user_message("root", "k", "gpt-5")
    sib_a, _ = @chat.add_user_message("sib-a leaf", "k", "gpt-5", root.execution_id)
    sib_b, _ = @chat.add_user_message("sib-b leaf", "k", "gpt-5", root.execution_id)

    # Reload to compare at PG timestamp precision (see G1 for the same fix).
    root_before  = root.reload.attributes.dup
    sib_b_before = sib_b.reload.attributes.dup

    # Delete sib_a as a leaf.
    destroy_leaf(sib_a)

    assert_equal root_before,  root.reload.attributes,  "root must be untouched by sibling-leaf deletion"
    assert_equal sib_b_before, sib_b.reload.attributes, "the surviving sibling must be untouched"
  end

  test "G6: deleting a leaf does not affect its former sibling's context" do
    root, _ = @chat.add_user_message("root question", "k", "gpt-5")
    root.update!(response: "root answer")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: root)

    sib_a, _ = @chat.add_user_message("sib-a", "k", "gpt-5", root.execution_id)
    sib_a.update!(response: "sib-a answer")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: sib_a)

    sib_b, _ = @chat.add_user_message("sib-b", "k", "gpt-5", root.execution_id)
    sib_b.update!(response: "sib-b answer")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: sib_b)

    # Delete sib_a (and its referencing messages, matching the app's leaf
    # deletion path).
    destroy_leaf(sib_a)

    # Continue on sib_b's branch. Context should include root + sib_b only.
    followup, _ = @chat.add_user_message("followup on b", "k", "gpt-5", sib_b.execution_id)

    messages = nil
    with_stub(LlmMetaClient::ServerResource, :available_llm_options,
              [ { uuid: "k", llm_type: "openai" } ]) do
      messages, _ = @chat.send(:build_streaming_messages, followup, "jwt")
    end
    joined = messages.map { |m| m[:content] }.join("\n")

    assert_includes joined, "root question", "root ancestor must remain in sib_b's context"
    assert_includes joined, "sib-b",         "sib_b's own turn must remain in its context"
    refute_includes joined, "sib-a",         "deleted sibling must not leak in"
  end
end
