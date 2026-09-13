# Presents a root prompt execution as a child of the history pane's synthetic
# Start node.
#
# prompt_navigator's card partial derives the arrow's parent from
# `ann.previous`, which is nil for a root. Nothing therefore tied the roots to
# the Start card, and a chat with several independent roots looked like
# several unexplained top-level entries rather than one tree.
#
# Wrapping the execution here rather than forking the gem's partial is
# deliberate: the card markup — model labels, document previews, the
# direction-agnostic adjacency arrow — keeps coming from the gem and keeps
# improving with it. An earlier attempt did fork the partial, against a stale
# vendored copy, and silently reverted two of those features.
class RootLinkedExecution < SimpleDelegator
  # Only needs to answer `execution_id`; that is all the partial reads off
  # `previous`.
  StartNode = Struct.new(:execution_id)

  def previous
    StartNode.new(Chat::ROOT_PARENT)
  end
end
