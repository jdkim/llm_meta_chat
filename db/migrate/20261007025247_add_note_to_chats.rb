# A free-text note about the chat as a whole.
#
# Two uses it serves: a hint for the audience on a demo (public) chat, and a
# memo to self about where a conversation was left off. It is shown to anyone
# who can open the chat — which keeps notes on private chats private, since the
# chat itself is.
class AddNoteToChats < ActiveRecord::Migration[8.1]
  def change
    add_column :chats, :note, :text
  end
end
