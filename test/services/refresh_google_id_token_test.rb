require "test_helper"

class RefreshGoogleIdTokenTest < ActiveSupport::TestCase
  TOKEN_URL = "https://oauth2.googleapis.com/token"

  setup do
    @user = User.create!(email: "u@example.com", google_id: "g-1",
                          id_token: "old.jwt.tok",
                          refresh_token: "rt-abc",
                          id_token_expires_at: 1.hour.ago)
    @saved_env = { "GOOGLE_CLIENT_ID" => ENV["GOOGLE_CLIENT_ID"],
                   "GOOGLE_CLIENT_SECRET" => ENV["GOOGLE_CLIENT_SECRET"] }
    ENV["GOOGLE_CLIENT_ID"]     = "client-id-x"
    ENV["GOOGLE_CLIENT_SECRET"] = "client-secret-y"
  end

  teardown do
    @saved_env.each { |k, v| ENV[k] = v }
  end

  test "POSTs grant_type=refresh_token + client creds to Google, updates id_token + expires_at on success" do
    stub_request(:post, TOKEN_URL)
      .with(body: hash_including(
        "grant_type" => "refresh_token",
        "refresh_token" => "rt-abc",
        "client_id" => "client-id-x",
        "client_secret" => "client-secret-y"
      ))
      .to_return(status: 200,
                 body: { "id_token" => "new.jwt.tok", "expires_in" => 3600,
                         "token_type" => "Bearer", "scope" => "openid email profile" }.to_json,
                 headers: { "Content-Type" => "application/json" })

    assert_equal true, RefreshGoogleIdToken.call(@user)
    @user.reload
    assert_equal "new.jwt.tok", @user.id_token
    assert_in_delta Time.current + 3600.seconds, @user.id_token_expires_at, 5.seconds
    # refresh_token preserved on success
    assert_equal "rt-abc", @user.refresh_token
  end

  test "returns false and clears stored credentials on 400 invalid_grant (refresh_token revoked)" do
    stub_request(:post, TOKEN_URL).to_return(
      status: 400,
      body: { "error" => "invalid_grant", "error_description" => "Token has been expired or revoked." }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    assert_equal false, RefreshGoogleIdToken.call(@user)
    @user.reload
    assert_nil @user.refresh_token
    assert_nil @user.id_token
    assert_nil @user.id_token_expires_at
  end

  test "returns false WITHOUT clearing credentials on transient errors (5xx, network)" do
    stub_request(:post, TOKEN_URL).to_return(status: 503, body: "<html>Service Unavailable</html>")

    assert_equal false, RefreshGoogleIdToken.call(@user)
    @user.reload
    # We want the next request to retry — don't drop the refresh_token.
    assert_equal "rt-abc", @user.refresh_token
    assert_equal "old.jwt.tok", @user.id_token
  end

  test "returns false and never POSTs when the user has no refresh_token" do
    @user.update_columns(refresh_token: nil)
    # Strict: no stub registered for the URL, so WebMock would raise on
    # any attempt to call out.
    assert_equal false, RefreshGoogleIdToken.call(@user)
  end

  test "returns false on network error (Timeout, SocketError) without raising" do
    stub_request(:post, TOKEN_URL).to_raise(SocketError.new("getaddrinfo failed"))
    assert_equal false, RefreshGoogleIdToken.call(@user)
    @user.reload
    assert_equal "rt-abc", @user.refresh_token
  end
end
