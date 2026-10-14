class Users::OmniauthCallbacksController < Devise::OmniauthCallbacksController
  # Generic handler for EGI / OIDC providers
  def egi
    handle_auth("EGI")
  end

  # Generic failure action for handling access denied or invalid callbacks
  def failure
    flash[:alert] = "Authentication failed: #{failure_message}"
    redirect_to root_path
  end

  private

  def handle_auth(kind)
    auth = request.env["omniauth.auth"]
    @user = User.from_omniauth(auth)

    if @user.persisted?
      # Log the user in and set a success flash message
      sign_in_and_redirect @user, event: :authentication
      set_flash_message(:notice, :success, kind: kind) if is_navigational_format?
    else
      # Safely extract minimal session data so registration form can pre-fill
      info = auth.info || {}
      session["devise.#{kind.downcase}_data"] = {
        provider: auth.provider,
        uid: auth.uid,
        email: info["email"] || info[:email],
        first_name: info["first_name"] || info[:given_name],
        last_name: info["last_name"] || info[:family_name]
      }.compact

      # Capture validation errors in logs to simplify debugging
      Rails.logger.error "[OmniAuth] Failed to persist user for #{auth.provider}: #{@user.errors.full_messages.join(', ')}"
      flash[:alert] = @user.errors.full_messages.join("\n") if @user.errors.any?

      redirect_to new_user_registration_url
    end
  end
end
