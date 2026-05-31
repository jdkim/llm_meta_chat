require "test_helper"

class UserTest < ActiveSupport::TestCase
  # --- from_omniauth ---------------------------------------------------- #

  def google_auth(email: "u@example.com", uid: "g-uid", id_token: "id.jwt.tok",
                  refresh_token: "rt-abc", expires_at: 1.hour.from_now.to_i)
    OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: uid,
      info: { email: email },
      credentials: { refresh_token: refresh_token, expires_at: expires_at },
      extra: { id_token: id_token }
    )
  end

  test "from_omniauth captures id_token, refresh_token, and id_token_expires_at on first sign-in" do
    user = User.from_omniauth(google_auth(refresh_token: "rt-1", expires_at: 1.hour.from_now.to_i))
    assert user.persisted?
    assert_equal "id.jwt.tok", user.id_token
    assert_equal "rt-1", user.refresh_token
    assert_in_delta 1.hour.from_now, user.id_token_expires_at, 5.seconds
  end

  test "from_omniauth preserves existing refresh_token when subsequent sign-in doesn't include one" do
    # First sign-in: Google issues a refresh_token.
    User.from_omniauth(google_auth(refresh_token: "rt-first"))
    # Second sign-in: Google omits refresh_token (typical after first consent).
    user = User.from_omniauth(google_auth(refresh_token: nil))
    assert_equal "rt-first", user.refresh_token, "must not clobber the existing refresh_token"
  end

  test "from_omniauth refreshes the id_token + expires_at on subsequent sign-in" do
    User.from_omniauth(google_auth(id_token: "first.jwt", expires_at: 1.hour.from_now.to_i))
    user = User.from_omniauth(google_auth(id_token: "second.jwt", expires_at: 2.hours.from_now.to_i))
    assert_equal "second.jwt", user.id_token
    assert_in_delta 2.hours.from_now, user.id_token_expires_at, 5.seconds
  end

  # --- jwt_token / token_valid? / needs_reauth? ----------------------- #

  test "jwt_token returns the stored id_token when expires_at is in the future" do
    user = User.create!(email: "u@example.com", google_id: "g", id_token: "good.tok",
                         refresh_token: "rt", id_token_expires_at: 1.hour.from_now)
    assert_equal "good.tok", user.jwt_token
  end

  test "jwt_token triggers RefreshGoogleIdToken when expired AND refresh_token is present" do
    user = User.create!(email: "u@example.com", google_id: "g", id_token: "old.tok",
                         refresh_token: "rt", id_token_expires_at: 1.hour.ago)
    refresh_called = false
    fake_refresh = ->(arg) {
      refresh_called = true
      assert_equal user, arg
      # Mutate as the real service would.
      user.update_columns(id_token: "fresh.tok", id_token_expires_at: 1.hour.from_now)
      true
    }
    with_stub(RefreshGoogleIdToken, :call, fake_refresh) do
      assert_equal "fresh.tok", user.jwt_token
    end
    assert refresh_called
  end

  test "jwt_token returns nil when expired AND refresh fails" do
    user = User.create!(email: "u@example.com", google_id: "g", id_token: "old.tok",
                         refresh_token: "rt", id_token_expires_at: 1.hour.ago)
    with_stub(RefreshGoogleIdToken, :call, ->(_) { false }) do
      assert_nil user.jwt_token
    end
  end

  test "jwt_token returns nil when expired AND no refresh_token is stored" do
    user = User.create!(email: "u@example.com", google_id: "g", id_token: "old.tok",
                         refresh_token: nil, id_token_expires_at: 1.hour.ago)
    # No stub needed — refresh should be skipped entirely.
    assert_nil user.jwt_token
  end

  test "token_valid? falls back to the JWT's exp claim when id_token_expires_at is nil (legacy rows)" do
    # token_valid? decodes the JWT with signature verification OFF so it
    # only needs proper structure (three base64 parts). Use JWT.encode
    # so the header + signature are real, even with a throwaway secret.
    fake_jwt = JWT.encode({ "exp" => 1.hour.from_now.to_i }, "fake-secret", "HS256")
    user = User.create!(email: "u@example.com", google_id: "g", id_token: fake_jwt,
                         id_token_expires_at: nil)
    assert user.token_valid?
  end

  test "needs_reauth? is true exactly when jwt_token would return nil" do
    expired = User.create!(email: "u1@example.com", google_id: "g1", id_token: "old",
                            refresh_token: nil, id_token_expires_at: 1.hour.ago)
    fresh   = User.create!(email: "u2@example.com", google_id: "g2", id_token: "good",
                            refresh_token: "rt", id_token_expires_at: 1.hour.from_now)
    assert expired.needs_reauth?
    refute fresh.needs_reauth?
  end
end
