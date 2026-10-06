import Config

config :logger, :default_formatter, format: "$time [$level] $message\n", metadata: []
config :logger, level: :info
