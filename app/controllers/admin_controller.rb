# frozen_string_literal: true

# Super-user dashboard for chat.AIbranch. Shows chat-side stats and,
# when reachable, fetches hub-side stats from /api/admin/stats so the
# operator sees both halves in one view. Gated by User#super_user?
# (env-driven SUPER_USER_EMAILS allowlist); non-super-users get 404.
class AdminController < ApplicationController
  include ChatManager::ChatManageable
  include PromptNavigator::HistoryManageable

  before_action :authenticate_user!
  before_action :require_super_user!

  def index
    # Populate @chats / @history so the shared application layout's
    # sidebars render normally — they'd otherwise NPE on the layout's
    # call to chat_list(...).
    initialize_chat visible_chats_scope
    initialize_history []
    @chat_stats = AdminStats.collect
    @hub_stats = fetch_hub_stats
  end

  private

  def require_super_user!
    raise ActionController::RoutingError, "Not Found" unless current_user&.super_user?
  end

  # Calls hub's /api/admin/stats with the current user's Google ID token.
  # Returns the parsed hash on success, or a `{error: ...}` hash so the
  # view can show a graceful degraded state rather than 500ing.
  def fetch_hub_stats
    return { error: "no JWT — can't reach hub" } if current_user.jwt_token.blank?
    uri = URI.join(Rails.configuration.llm_service_base_url, "/api/admin/stats")
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", read_timeout: 5) do |http|
      req = Net::HTTP::Get.new(uri)
      req["Authorization"] = "Bearer #{current_user.jwt_token}"
      req["Accept"] = "application/json"
      http.request(req)
    end
    response.is_a?(Net::HTTPSuccess) ? JSON.parse(response.body) : { error: "hub returned HTTP #{response.code}" }
  rescue StandardError => e
    { error: "#{e.class}: #{e.message}" }
  end
end
