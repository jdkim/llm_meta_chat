# Read the app's semantic version from the top-level VERSION file at boot.
# Bump the file's contents manually when a release feels warranted; this
# constant is exposed through ApplicationHelper#app_version and shown next
# to the brand in the header.
module AppVersion
  CURRENT = begin
    Rails.root.join("VERSION").read.strip.presence
  rescue Errno::ENOENT
    nil
  end || "unknown"
end
