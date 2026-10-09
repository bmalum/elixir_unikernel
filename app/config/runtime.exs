import Config

# Evaluated at boot inside the image (reboot_system_after_config defaults to false,
# so no VM restart / writable release dir is needed).
if level = System.get_env("UNIAPP_LOG_LEVEL") do
  config :logger, level: String.to_existing_atom(level)
end

# The image's CA bundle (see builder/Dockerfile). `:public_key.cacerts_get/0`,
# which `:httpc` calls for every request, looks here instead of the OS paths
# the image does not have.
config :public_key, cacerts_path: System.get_env("UNIAPP_CACERTS") || "/etc/ssl/cacert.pem"
