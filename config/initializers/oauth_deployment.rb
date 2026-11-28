Rails.application.config.after_initialize do
  building_assets = defined?(Rake) && Rake.respond_to?(:application) && Rake.application.top_level_tasks.include?("assets:precompile")
  OauthConfig.validate_deployment! if Rails.env.production? && !building_assets
end
