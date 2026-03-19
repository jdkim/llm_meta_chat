class CreateMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :messages do |t|
      t.references :chat, null: false, foreign_key: true
      # t.references :parent, foreign_key: { to_table: :messages }, index: true, null: true
      t.references :prompt_navigator_prompt_execution, null: true, foreign_key: { to_table: :prompt_navigator_prompt_executions }
      t.string :role

      t.timestamps
    end
  end
end
