class Users::OmniauthCallbacksController < Devise::OmniauthCallbacksController
  def google_oauth2
    @user = User.from_omniauth(request.env["omniauth.auth"])

    # Check if the user was successfully saved to the database
    if @user.persisted?
      # Auto-claim any anonymous chats this browser session created
      # before sign-in, so the user's pre-login work continues seamlessly
      # under their account. Best-effort: failures don't block the
      # sign-in flow.
      anon_token = session[:anon_chat_token]
      if anon_token.present?
        claimed = Chat.where(user_id: nil, session_id: anon_token)
                      .update_all(user_id: @user.id, session_id: nil)
        Rails.logger.info "[OmniauthCallbacks] auto-claimed #{claimed} anonymous chats for user #{@user.id}" if claimed.positive?
      end

      # Authentication successful: Set flash message and sign in with redirect
      flash[:notice] = I18n.t "devise.omniauth_callbacks.success", kind: "Google"
      sign_in_and_redirect @user, event: :authentication
    else
      # Authentication failed: User creation/validation errors occurred
      # This happens when:
      # - Email validation fails
      # - Required fields are missing
      # - Database constraints are violated
      # - User model validations fail

      # Redirect to home with error messages
      redirect_to root_path, alert: @user.errors.full_messages.join("\n")
    end
  end

  def failure
    redirect_to root_path, alert: "Failed to authentication. Please try again."
  end
end
