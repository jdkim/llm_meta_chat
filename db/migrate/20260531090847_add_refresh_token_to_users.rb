class AddRefreshTokenToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :refresh_token, :text
    add_column :users, :id_token_expires_at, :datetime
  end
end
