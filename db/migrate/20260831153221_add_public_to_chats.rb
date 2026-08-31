class AddPublicToChats < ActiveRecord::Migration[8.1]
  def change
    add_column :chats, :public, :boolean, default: false, null: false
    add_index :chats, :public, where: "public = true", name: "idx_chats_public_when_true"
  end
end
