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

  # Turbo Drive paints a cached preview before swapping in the fresh body, so a
  # node located immediately after a navigation can belong to a document that
  # is about to be thrown away. The symptom arrives later and elsewhere —
  # "Node with given id does not belong to the document" — in whichever test
  # lost that race, which is why it looked like random flake across unrelated
  # files. Wait the preview out on every navigation instead.
  def visit(*, **)
    super
    wait_for_turbo
  end

  def wait_for_turbo(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      settled = page.evaluate_script(
        "document.readyState === 'complete' && " \
        "!document.documentElement.hasAttribute('data-turbo-preview')"
      )
      break if settled
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
  end

  # Selenium action chains (hover, ctrl+click) hold a raw node handle that
  # Capybara will not re-resolve the way it re-resolves its own elements. If
  # anything re-renders between finding the node and performing the action,
  # Chrome fails the whole action with "Node with given id does not belong to
  # the document" — intermittently, in whichever test happens to lose the race.
  #
  # Re-find and retry rather than sleep: the node is fine, the handle is not.
  def retrying_stale(attempts: 3)
    tries = 0
    begin
      yield
    rescue Selenium::WebDriver::Error::StaleElementReferenceError,
           Selenium::WebDriver::Error::UnknownError => e
      stale = e.is_a?(Selenium::WebDriver::Error::StaleElementReferenceError) ||
              e.message.include?("does not belong to the document")
      raise unless stale

      tries += 1
      raise if tries >= attempts

      sleep 0.15
      retry
    end
  end

  # Ctrl/cmd+click, re-finding the node on each attempt. Takes a block rather
  # than an element so a retry resolves a fresh one.
  def ctrl_click(&finder)
    retrying_stale do
      node = finder.call
      page.driver.browser.action.key_down(:control).click(node.native).key_up(:control).perform
    end
  end

  # Same for hover.
  def hover_over(&finder)
    retrying_stale { finder.call.hover }
  end
end
