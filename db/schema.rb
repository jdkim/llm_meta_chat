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

ActiveRecord::Schema[8.1].define(version: 2026_03_19_052219) do
  create_table "chats", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "llm_uuid"
    t.string "model"
    t.string "title"
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.string "uuid", null: false
    t.index ["user_id"], name: "index_chats_on_user_id"
  end

  create_table "messages", force: :cascade do |t|
    t.integer "chat_id", null: false
    t.datetime "created_at", null: false
    t.integer "prompt_navigator_prompt_execution_id"
    t.string "role"
    t.datetime "updated_at", null: false
    t.index ["chat_id"], name: "index_messages_on_chat_id"
    t.index ["prompt_navigator_prompt_execution_id"], name: "index_messages_on_prompt_navigator_prompt_execution_id"
  end

  create_table "prompt_navigator_prompt_executions", force: :cascade do |t|
    t.string "configuration"
    t.datetime "created_at", null: false
    t.string "execution_id"
    t.string "llm_platform"
    t.string "model"
    t.integer "previous_id"
    t.text "prompt"
    t.text "response"
    t.datetime "updated_at", null: false
    t.index ["previous_id"], name: "index_prompt_navigator_prompt_executions_on_previous_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "google_id"
    t.text "id_token"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["google_id"], name: "index_users_on_google_id", unique: true
  end

  add_foreign_key "chats", "users"
  add_foreign_key "messages", "chats"
  add_foreign_key "messages", "prompt_navigator_prompt_executions"
  add_foreign_key "prompt_navigator_prompt_executions", "prompt_navigator_prompt_executions", column: "previous_id"
end
