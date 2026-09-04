class AddReasoningToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :reasoning, :text
  end
end
