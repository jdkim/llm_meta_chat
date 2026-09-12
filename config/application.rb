require_relative "boot"

require "rails"

# Pick the frameworks you want. This was `rails/all`, which loaded
# ActiveStorage, ActionText and ActionMailbox — none of which this app uses:
# no attachments are declared anywhere, there are no active_storage tables,
# and images travel as base64 data URIs inside the prompt (see Chat#add_user_message).
# The only visible effect was ActiveStorage warning on every boot that libvips
# is missing, for a variant processor nothing ever calls.
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_view/railtie"
require "action_cable/engine"
# require "action_mailbox/engine"
# require "action_text/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module LlmMetaChat
  class Application < Rails::Application
    # Add asset paths for prompt_navigator gem
    config.assets.paths << Rails.root.join("../prompt_navigator/app/assets/stylesheets")
    # Add asset paths for chat_manager gem
    config.assets.paths << Rails.root.join("../chat_manager/app/assets/stylesheets")
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
