# frozen_string_literal: true
#
# Cookbook:: chef_client_updater_enterprise
# Resource:: Partial:: _partials
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
         regex: %r{\A[a-zA-Z0-9][\w.-]*/[a-zA-Z0-9][\w.-]*\z},
         description: 'Habitat package identifier, as a bare `origin/name` ident.',
         default: 'chef/chef-infra-client'

property :version, String,
         coerce: proc { |v| v.to_s.casecmp('latest').zero? ? 'latest' : v.to_s },
         description: "Version to install. 'latest' (any casing) resolves to the latest release " \
                      'in the configured channel.',
         default: 'latest'
