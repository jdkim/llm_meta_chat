# Supplement edges: a prompt may reference other executions whose content is
# injected as reference material for that one turn.
#
# The primary chain (`previous_id`) is deliberately untouched. It stays exactly
# one parent, because history serialization walks it and must stay
# deterministic — these edges add a DAG for *context* while the *structure*
# remains a tree.
#
# Nothing here records what the user meant to do with the references
# (compare them, merge them, weigh them). That is said in the prompt itself.
# The edge means one thing only: this content is available to that turn.
class AddPromptNavigatorSupplements < ActiveRecord::Migration[8.1]
  def change
    create_table :prompt_navigator_supplements do |t|
      # The prompt that carries the references.
      t.references :prompt_execution,
                   foreign_key: { to_table: :prompt_navigator_prompt_executions },
                   null: false, index: { name: "idx_pn_supplements_on_execution" }
      # The execution being referenced.
      t.references :supplement_execution,
                   foreign_key: { to_table: :prompt_navigator_prompt_executions },
                   null: false, index: { name: "idx_pn_supplements_on_supplement" }
      # Selection order, so the injected material reads back in the order the
      # user picked rather than by insertion id.
      t.integer :position, null: false, default: 0

      t.timestamps
    end

    # Explicit names throughout: the generated ones would exceed Postgres's
    # 63-character identifier limit and be silently truncated.
    add_index :prompt_navigator_supplements,
              [ :prompt_execution_id, :supplement_execution_id ],
              unique: true, name: "idx_pn_supplements_pair"
  end
end
