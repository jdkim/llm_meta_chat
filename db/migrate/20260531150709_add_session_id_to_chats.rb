class AddSessionIdToChats < ActiveRecord::Migration[8.1]
  def change
    add_column :chats, :session_id, :string
    add_index :chats, :session_id
  end
end
