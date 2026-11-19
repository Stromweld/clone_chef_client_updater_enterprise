default['chef_client_updater_enterprise']['license_key'] = ENV.fetch('CHEF_LICENSE_KEY', nil)
# TODO: switch back to 'stable' once a stable chef-ice newer than 19.4.50 ships.
# The cookbook refuses releases up to 19.4.50; today only 'current' (19.4.56) qualifies.
default['chef_client_updater_enterprise']['channel'] = 'current'
