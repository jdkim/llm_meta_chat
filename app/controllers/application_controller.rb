class ApplicationController < ActionController::Base
  before_action :load_public_chats
  # PromptNavigator's labels are process-global, so every request must know
  # them — not just the ones that fetch the catalog. See ModelLabelRegistry.
  before_action :warm_model_labels
  include LlmMetaClient::Helpers
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  helper_method :visible_chats_scope, :anonymous_session_token

  # The set of chats the current visitor is allowed to see / modify:
  #   * signed-in users  → their own chats (`user_id = current_user.id`)
  #   * anonymous users  → chats stamped with the current browser
  #                        session ID (`session_id = anonymous_session_token`,
  #                        `user_id IS NULL`)
  # Single source of truth for both the sidebar and individual lookups.
  def visible_chats_scope
    if user_signed_in?
      current_user.chats
    else
      Chat.where(session_id: anonymous_session_token, user_id: nil)
    end
  end

  # Stable identifier for the current browser session, used to stamp
  # anonymous chats. We mint and store our own random token in the
  # session itself rather than relying on `session.id` (which is not
  # always populated on Rails CookieStore). The token survives across
  # requests as long as the session cookie does — exactly the lifetime
  # we want for anonymous chat persistence.
  def anonymous_session_token
    session[:anon_chat_token] ||= SecureRandom.hex(16)
  end

  private

  # Fetches the model catalog and registers its display names, so a turn is
  # labelled by its model ("Qwen3.6 35B") rather than by its platform
  # ("Ollama"). See ModelLabelRegistry.
  def warm_model_labels
    ModelLabelRegistry.warm!
  end

  def fetch_llm_families(jwt_token)
    families = LlmMetaClient::ServerResource.available_llm_families(jwt_token)
    # "Free" spans providers, so it replaces the gem's ollama family rather
    # than sitting beside it: a free model is defined by the catalog flag,
    # not by who hosts it, and listing an Ollama model twice (once as
    # "Local Ollama", once as Free) would be both duplicated and misleading.
    free = FreeModelFamily.build
    families = families.reject { |f| f[:llm_type].to_s == "ollama" } + free if free.any?
    ModelLabelRegistry.register(families)
    families
  end

  private

  # The Demo chats pane lives in the LAYOUT, so every controller that renders a
  # page — or replaces the sidebar over Turbo Stream — needs @public_chats.
  # Keeping this in ChatsController alone made the pane vanish in two places:
  # on /prompts/:id (PromptsController renders the same layout), and after a
  # streamed answer, because ChatStreamsController#render_sidebar_update
  # re-renders chats/_chat_sidebar and the pane came back empty.
  #
  # @featured_public_chat is the oldest public chat and drives the landing
  # hero's call to action on chats#new.
  def load_public_chats
    @public_chats = Chat.publicly_viewable.order(created_at: :desc).limit(10).to_a
    @featured_public_chat = @public_chats.min_by(&:created_at)
  end
end
