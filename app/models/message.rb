class Message < ApplicationRecord
  belongs_to :chat, touch: true
  belongs_to :prompt_navigator_prompt_execution,
             class_name: "PromptNavigator::PromptExecution",
             optional: false

  validates :role, presence: true, inclusion: { in: %w[user assistant] }
end
