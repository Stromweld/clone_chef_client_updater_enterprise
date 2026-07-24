# frozen_string_literal: true
#
# InSpec Integration Test:: default
#
# Verifies chef-ice was installed and binlinked correctly.

title 'chef-ice installation verification'

# chef-client binary must be callable and report the correct product name
describe command('chef-client --version') do
  its('exit_status') { should eq 0 }
  its('stdout') { should match(/Chef Infra Client/) }
end

# Platform-specific binlink checks
# Linux: explicit --dest /usr/bin (well-known, always in PATH)
if os.linux?
  describe file('/usr/bin/chef-client') do
    it { should exist }
    it { should be_symlink }
    it { should be_executable }
  end
end

# macOS: explicit --dest /usr/local/bin (SIP protects /usr/bin)
if os.darwin?
  describe file('/usr/local/bin/chef-client') do
    it { should exist }
    it { should be_symlink }
    it { should be_executable }
  end
end

# Windows: Habitat default C:\hab\bin
if os.windows?
  describe file('C:\hab\bin\chef-client.bat') do
    it { should exist }
  end
end
