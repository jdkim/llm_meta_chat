# The catalog's display name for the model that answered, captured when the turn
# is written.
#
# Without it the sidebar resolves a label from the host's LIVE model catalog, so
# a turn's label depends on whether that model is still offered today. Retiring a
# model silently downgraded every past turn that used it to the platform name:
# on one production history, 350 of 520 turns had already decayed that way,
# including Ollama-hosted ones showing "Ollama" — the exact case the per-model
# label exists to fix. A history row has to carry what it needs.
class AddModelLabelToPromptNavigatorPromptExecutions < ActiveRecord::Migration[8.1]
  def change
    add_column :prompt_navigator_prompt_executions, :model_label, :string
  end
end
