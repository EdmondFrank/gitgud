defmodule GitGud.MailerTest do
  use GitGud.Web.ConnCase, async: true
  use GitGud.Web.DataFactory

  alias GitGud.User

  setup do
    user = User.create!(factory(:user))
    [email] = user.emails
    {:ok, user: user, email: struct(email, user: user)}
  end

  test "verification email contains an absolute verification URL", %{email: email} do
    mail = GitGud.Mailer.verification_email(email)
    url = GitGud.Web.Endpoint.url() <> "/settings/emails/verify/"

    assert mail.subject == "Verify your email address"
    # The verification URL has to be absolute since it leaves the app through the mailer.
    assert mail.text_body =~ url
    assert mail.html_body =~ url
    # The HTML body is wrapped in the `GitGud.Web.Layouts` mailer layout.
    assert mail.html_body =~ "<!DOCTYPE html>"
  end

  test "password reset email contains an absolute reset URL", %{email: email, user: user} do
    mail = GitGud.Mailer.password_reset_email(email)
    url = GitGud.Web.Endpoint.url() <> "/password/reset/"

    assert mail.subject == "Reset your password"
    assert mail.text_body =~ user.login
    # The reset URL has to be absolute since it leaves the app through the mailer.
    assert mail.text_body =~ url
    assert mail.html_body =~ url
    assert mail.html_body =~ "<!DOCTYPE html>"
  end
end
