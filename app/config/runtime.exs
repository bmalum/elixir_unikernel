import Config

# Evaluated at boot inside the image (reboot_system_after_config defaults to false,
# so no VM restart / writable release dir is needed).
if level = System.get_env("UNIAPP_LOG_LEVEL") do
  config :logger, level: String.to_existing_atom(level)
end
