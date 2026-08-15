# Host-side override for chat_manager 1.2.1's CSV download. The gem calls
# `chat.model` on each row, but this host stores model per-message on the
# PromptExecution (not per-chat) — reflecting that users can switch models
# turn-by-turn. Upstream assumption of "one chat = one model" is stale.
#
# Fix: use pe&.model (the PromptExecution that IS in scope in the loop)
# for the per-row Model column, so the CSV faithfully records which model
# generated each assistant turn (and — by convention — which model was
# active when each user prompt was sent).
#
# Filed for a proper chat_manager release as Fix B; this override unblocks
# the SoftwareX resubmission supplementary-data CSV export in the meantime.

require "chat_manager/csv_downloadable"
require "csv"

module ChatManager
  module CsvDownloadable
    def generate_csv_for_chats(chats)
      CSV.generate do |csv|
        csv << CSV_HEADERS
        chats.each do |chat|
          chat.ordered_messages.each do |msg|
            pe = msg.prompt_navigator_prompt_execution
            content = msg.role == "user" ? pe&.prompt : pe&.response
            csv << [ chat.title, msg.role, content, msg.created_at, pe&.model ]
          end
        end
      end
    end
  end
end
