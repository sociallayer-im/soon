# The ticket-selling domain. Already the namespace for its services
# (Ticketing::Quote, Ticketing::DesignateGroupTicketEvent) and its cron job;
# this makes it a model namespace too, so Ticketing::Activity does not have to
# fight the top-level Activity — which is the user notification feed and an
# entirely different thing.
module Ticketing
  def self.table_name_prefix = "ticketing_"
end
