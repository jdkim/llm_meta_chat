require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ] do |options|
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")

    # Selenium puts the browser profile under /tmp by default. A
    # snap-packaged Chromium — what this machine has — is confined and cannot
    # write there, and the failure mode is silent: chromedriver starts, the
    # browser never becomes controllable, and the run dies 120s later with a
    # bare `Net::ReadTimeout` naming nothing. Somewhere under the project
    # (still inside $HOME, not a dotted path) is writable under confinement
    # and harmless on a normal Chrome, so it works in CI too.
    #
    # Per-process so parallel workers cannot share one profile.
    profile = Rails.root.join("tmp", "system-test-profile-#{Process.pid}")
    FileUtils.mkdir_p(profile)
    options.add_argument("--user-data-dir=#{profile}")
    at_exit { FileUtils.rm_rf(profile) }
  end
end
