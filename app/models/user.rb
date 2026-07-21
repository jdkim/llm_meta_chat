class User < ApplicationRecord
  devise :omniauthable, omniauth_providers: %i[google_oauth2]

  has_many :chats, -> { order(:updated_at) }, dependent: :destroy

  validates :email, presence: true, uniqueness: true
  validates :google_id, presence: true, uniqueness: true
  validates :id_token, presence: true

  def self.from_omniauth(auth)
    user = where(email: auth.info.email).first_or_initialize(
      google_id: auth.uid
    )

    token = auth.extra&.id_token
    if token.blank?
      user.errors.add(:id_token, "is missing from provider response")
      return user
    end

    user.id_token = token
    user.id_token_expires_at = derive_expires_at(auth, token)
    # Google only emits refresh_token on the FIRST consent per
    # user × client (unless prompt=consent forces re-issue). Preserve
    # whatever's already stored when the current sign-in didn't include
    # a fresh one — otherwise re-signing in would silently lose offline
    # access until the user revoked + reconsented.
    new_refresh = auth.credentials&.refresh_token
    user.refresh_token = new_refresh if new_refresh.present?

    user.save
    user
  end

  # Source the canonical token-expiry timestamp from Google's credentials
  # if present (most reliable). Falls back to decoding the id_token's
  # `exp` claim. Returns nil if neither is available — `token_valid?`
  # then treats the token as expired and triggers refresh.
  def self.derive_expires_at(auth, id_token)
    if (e = auth.credentials&.expires_at)
      return Time.at(e.to_i)
    end
    payload = JWT.decode(id_token, nil, false).first
    Time.at(payload["exp"]) if payload && payload["exp"]
  rescue StandardError
    nil
  end

  # Returns a valid Google ID token, refreshing it via the stored
  # refresh_token if the current one has expired. Returns nil when no
  # valid token is available AND no refresh path exists — the caller
  # should treat that as "this user needs to sign in again."
  def jwt_token
    return id_token if id_token.present? && token_valid?
    return nil if refresh_token.blank?
    RefreshGoogleIdToken.call(self) ? id_token : nil
  end

  # True when the in-memory id_token is still usable. We consult the
  # stored expires_at first (set on omniauth callback / after each
  # refresh) and fall back to decoding the JWT's `exp` claim for rows
  # populated before id_token_expires_at was added.
  def token_valid?
    return false if id_token.blank?
    return Time.current < id_token_expires_at if id_token_expires_at.present?

    payload = JWT.decode(id_token, nil, false).first
    exp = payload && payload["exp"]
    exp && Time.now.to_i < exp
  rescue JWT::DecodeError, JWT::ExpiredSignature
    false
  end

  # True when the user is in an unrecoverable auth state — i.e., we
  # can't satisfy a meta-server call without bouncing them through
  # Google again. Surfaced by the UI as a re-auth banner.
  def needs_reauth?
    jwt_token.nil?
  end

  # True if this user's email is listed in the SUPER_USER_EMAILS env
  # (comma-separated). Cheap config-driven authorization — no DB
  # column, no admin UI required to add/remove super users; just edit
  # the env file and restart.
  def super_user?
    self.class.super_user_emails.include?(email.to_s.downcase)
  end

  def self.super_user_emails
    ENV.fetch("SUPER_USER_EMAILS", "").split(",").map { |e| e.strip.downcase }.reject(&:empty?)
  end
end
