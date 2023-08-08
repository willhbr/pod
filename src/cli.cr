require "./pod"

default = Log::Severity::Error
{% unless flag? :release %}
  default = Log::Severity::Debug
{% end %}

severity = Log::Severity.parse?(ENV["POD_LOG_LEVEL"]? || "error") || default

Colorize.on_tty_only!
Log.setup do |l|
  l.stderr(severity: severity)
end
Log.info { "Logging at: #{severity}" }

Log.debug { "ARGV: #{ARGV.inspect}" }
Pod::CLI.start(ARGV)
