source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.3"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Bundle and transpile JavaScript [https://github.com/rails/jsbundling-rails]
gem "jsbundling-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Bundle and process CSS [https://github.com/rails/cssbundling-rails]
gem "cssbundling-rails"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
gem "jbuilder"
# Use Redis adapter to run Action Cable in production
# gem "redis", ">= 4.0.1"

# Hashes OAuth client secrets (OauthApplication). Not used for user passwords —
# soon has none; every sign-in path is a code, a wallet signature or an OAuth
# provider.
gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 1.2"

gem "blueprinter"
gem "pagy"
# Postgres-backed Active Job backend. Runs inside the Puma process
# (execution_mode :async, see config/initializers/good_job.rb) so there is no
# separate worker to deploy — but unlike Rails' built-in :async adapter, jobs
# are rows in the database, so a restart or crash doesn't drop queued mail.
gem "good_job", "~> 4.19"
gem "jwt"
gem "pundit"
gem "rack-cors"
gem "oga"
gem "resend"
gem "icalendar"
gem "httpx"
# Image uploads go to the Cloudflare R2 bucket behind datastore.sola.day over
# its S3-compatible API — see app/services/object_store.rb for why that host
# and not Cloudflare Images.
gem "aws-sdk-s3", "~> 1.0", require: false
gem "eth"
# Sign-In with Ethereum message parsing/verification. Not spruceid/siwe-ruby
# (the original gem "siwe") — that's unmaintained (last real commit 2023-07,
# published to rubygems 2022). Reviewed the full lib/ of this replacement
# before adopting — see soon/design/ (siwe-rb code review) for notes; the
# smart-contract-wallet (ERC-1271/6492) RPC path is intentionally never
# configured, so it's dead code for us (EOA wallets only).
gem "siwe-rb", "~> 0.1", require: "siwe"
gem "stripe"

group :development, :test do
  # Loads environment variables from .env [https://github.com/bkeepers/dotenv]
  gem "dotenv-rails"

  # object.stub for controller tests that mock external services (e.g. EvmPaymentVerifier)
  gem "minitest-mock", require: "minitest/mock"

  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"
end
