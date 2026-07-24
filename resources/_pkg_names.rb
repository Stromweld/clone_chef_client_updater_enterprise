# frozen_string_literal: true
#
# Cookbook:: chef_client_updater_enterprise
# Resource:: Partial:: _pkg_names
#
# Copyright:: 2026, Corey Hemminger
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

property :habitat_package, String,
         description: 'Habitat package identifier.',
         default: 'chef/chef-infra-client'

property :product_name, String,
         description: 'Mixlib-install product name and native OS package name.',
         default: 'chef-ice'

property :legacy_omnibus_package, String,
         description: 'Legacy omnibus package name to purge.',
         default: 'chef'
