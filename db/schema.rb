# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_04_084953) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "chats", force: :cascade do |t|
    t.timestamptz "created_at"
    t.boolean "public", default: false, null: false
    t.text "session_id"
    t.text "title"
    t.timestamptz "updated_at"
    t.bigint "user_id"
    t.text "uuid"
    t.index ["public"], name: "idx_chats_public_when_true", where: "(public = true)"
    t.index ["session_id"], name: "idx_2679977_index_chats_on_session_id"
    t.index ["user_id"], name: "idx_2679977_index_chats_on_user_id"
  end

  create_table "messages", force: :cascade do |t|
    t.bigint "chat_id"
    t.timestamptz "created_at"
    t.bigint "prompt_navigator_prompt_execution_id"
    t.text "reasoning"
    t.text "role"
    t.timestamptz "updated_at"
    t.index ["chat_id"], name: "idx_2679984_index_messages_on_chat_id"
    t.index ["prompt_navigator_prompt_execution_id"], name: "idx_2679984_index_messages_on_prompt_navigator_prompt_execution"
  end

  create_table "prompt_navigator_prompt_executions", force: :cascade do |t|
    t.text "configuration"
    t.timestamptz "created_at"
    t.text "execution_id"
    t.text "llm_platform"
    t.text "llm_uuid"
    t.text "model"
    t.bigint "previous_id"
    t.text "prompt"
    t.text "response"
    t.timestamptz "updated_at"
    t.index ["previous_id"], name: "idx_2679991_index_prompt_navigator_prompt_executions_on_previou"
  end

  create_table "users", force: :cascade do |t|
    t.timestamptz "created_at"
    t.text "email"
    t.text "google_id"
    t.text "id_token"
    t.timestamptz "id_token_expires_at"
    t.text "refresh_token"
    t.timestamptz "updated_at"
    t.index ["email"], name: "idx_2679970_index_users_on_email", unique: true
    t.index ["google_id"], name: "idx_2679970_index_users_on_google_id", unique: true
  end

  add_foreign_key "chats", "users", name: "chats_user_id_fkey"
  add_foreign_key "messages", "chats", name: "messages_chat_id_fkey"
  add_foreign_key "messages", "prompt_navigator_prompt_executions", name: "messages_prompt_navigator_prompt_execution_id_fkey"
  add_foreign_key "prompt_navigator_prompt_executions", "prompt_navigator_prompt_executions", column: "previous_id", name: "prompt_navigator_prompt_executions_previous_id_fkey"
end
