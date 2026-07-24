name 'chef_client_updater_enterprise'
maintainer 'Corey Hemminger'
maintainer_email 'hemminger@hotmail.com'
license 'Apache-2.0'
description 'Installs and manages Chef Infra Client via chef-ice native OS packages, Habitat binlinks, and cleanup of legacy omnibus installations.'
version '0.1.0'

# Resource:: partials with the `use` directive require Chef Infra Client >= 17.0.
chef_version '>= 17.0'

issues_url 'https://github.com/chef-cookbooks/chef_client_updater_enterprise/issues'
source_url 'https://github.com/chef-cookbooks/chef_client_updater_enterprise'

%w(amazon centos debian fedora mac_os_x opensuseleap oracle redhat suse ubuntu windows).each do |os|
  supports os
end
