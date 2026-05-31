# frozen_string_literal: true

# Refreshes a User's Google ID token using their stored refresh_token.
#
# Google ID tokens expire after ~1 hour; the refresh_token (issued only
# when omniauth requested `access_type: offline` at sign-in time) lets us
# mint a fresh ID token without bouncing the user back through the
# consent flow.
#
# Returns true on success (the user's id_token + id_token_expires_at
# columns are updated in place), false on any failure. A 400 / invalid_grant
# response means the refresh_token was revoked (user removed access in
# their Google account settings) — we clear it so we stop retrying.
class RefreshGoogleIdToken
  TOKEN_URL = "https://oauth2.googleapis.com/token"

  def self.call(user)
    new(user).call
  end

  def initialize(user)
    @user = user
  end

  def call
    return false if @user.refresh_token.blank?
    return false if client_id.blank? || client_secret.blank?

    response = HTTParty.post(TOKEN_URL,
      headers: { "Content-Type" => "application/x-www-form-urlencoded" },
      body: {
        grant_type:    "refresh_token",
        refresh_token: @user.refresh_token,
        client_id:     client_id,
        client_secret: client_secret
      },
      timeout: 10)

    if response.success?
      apply!(response.parsed_response)
      true
    else
      handle_failure!(response)
      false
    end
  rescue StandardError => e
    Rails.logger.warn "[RefreshGoogleIdToken] #{e.class}: #{e.message}"
    false
  end

  private

  def apply!(body)
    return unless body.is_a?(Hash) && body["id_token"].present?

    new_expires_at = body["expires_in"] ? Time.current + body["expires_in"].to_i.seconds : nil
    @user.update_columns(
      id_token:            body["id_token"],
      id_token_expires_at: new_expires_at
    )
  end

  def handle_failure!(response)
    body = response.parsed_response
    error = body.is_a?(Hash) ? body["error"] : nil
    Rails.logger.warn "[RefreshGoogleIdToken] HTTP #{response.code} error=#{error.inspect}"

    # invalid_grant = refresh_token revoked or expired. Clear stored
    # credentials so jwt_token returns nil and the UI bounces the user
    # to a fresh sign-in instead of retrying on every request.
    if response.code == 400 && error.to_s == "invalid_grant"
      @user.update_columns(refresh_token: nil, id_token: nil, id_token_expires_at: nil)
    end
  end

  def client_id
    ENV["GOOGLE_CLIENT_ID"] || Rails.application.credentials.dig(:google, :client_id)
  end

  def client_secret
    ENV["GOOGLE_CLIENT_SECRET"] || Rails.application.credentials.dig(:google, :client_secret)
  end
end
