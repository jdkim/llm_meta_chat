# frozen_string_literal: true

# Aggregated chat-side stats for the super-user dashboard. Read-only;
# safe to call on every page render. Hub-side counters come from
# AdminController fetching /api/admin/stats on hub separately.
module AdminStats
  module_function

  def collect
    {
      generated_at: Time.current.iso8601,
      service: "chat",
      users: user_stats,
      chats: chat_stats,
      messages: message_stats,
      executions: execution_stats
    }
  end

  def user_stats
    {
      total: User.count,
      with_refresh_token: User.where.not(refresh_token: nil).count,
      recent_signups_7d: User.where("created_at >= ?", 7.days.ago).count,
      recent: User.order(created_at: :desc).limit(5).pluck(:email, :created_at)
    }
  end

  def chat_stats
    all = Chat.all
    {
      total: all.count,
      titled: all.where.not(title: nil).where.not(title: "").count,
      anonymous: all.where(user_id: nil).count,
      with_messages: Chat.joins(:messages).distinct.count
    }
  end

  def message_stats
    {
      total: Message.count,
      user_msgs: Message.where(role: "user").count,
      assistant_msgs: Message.where(role: "assistant").count
    }
  end

  def execution_stats
    pes = PromptNavigator::PromptExecution
    {
      total: pes.count,
      top_models_used: pes.where.not(model: [ nil, "" ]).group(:model).count.sort_by { |_, n| -n }.first(10).to_h
    }
  end
end
