# Author: Brant Evans    (bevans@redhat.com)
# Author: Jeffrey Cutter (jcutter@redhat.com
# Author: Andrew Becker  (anbecker@redhat.com)
# License: GPL v3
#
# Description: Add a host from an Ansible Inventory via API

require 'rest_client'
require 'json'

module AutomationManagement
  module AnsibleTower
    module Operations
      module Methods
        class AddHostToInventory
          include RedHatConsulting_Utilities::StdLib::Core
          
          TOWER_CONFIGURATION_URI = 'Integration/AnsibleTower/Configuration/default'.freeze
          
          def initialize(handle = $evm)
            @handle = handle
            @DEBUG = false
            @tower_config = @handle.instantiate(TOWER_CONFIGURATION_URI)
            @handle.log(:info, "Resolved Ansible Tower Configuration URI: #{@tower_config.name}") if @DEBUG
          end

          def check_configuration
            error("Ansible Tower Config not found at #{TOWER_CONFIGURATION_URI}") if @tower_config.blank?
            error("Ansible Tower URL not set") if @tower_config['tower_url'].blank?
            error("Ansible Tower Username not set") if @tower_config['tower_username'].blank?
            error("Ansible Tower Password not set") if @tower_config['tower_password'].blank?
          end

          def tower_request_url(api_path)
            api_version = @tower_config['tower_api_version']
            tower_url = @tower_config['tower_url']
            # build the URL for the REST request
            url = "#{tower_url}/api/#{api_version}/#{api_path}"
            # Tower expects the api path to end with a "/" so guarantee that it is there
            # Searches and filters don't like trailing / so exclude if includes =
            url << '/' unless url.end_with?('/') || url.include?('=')
            @handle.log(:info, "Call Tower API URL: <#{url}>") if @DEBUG
            return url
          end

          def tower_request(action, api_path, payload=nil)
            # build the REST request
            params = {
              :method     => action,
              :url        => tower_request_url(api_path),
              :user       => @tower_config['tower_username'],
              :password   => @tower_config['tower_password'],
              :verify_ssl => @tower_config['tower_verify_ssl'],
              :timeout    => @tower_config['tower_api_timeout']
              }
            params[:payload] = payload unless payload.nil?
            params[:headers] = {:content_type => 'application/json' } unless payload.nil?
            @handle.log(:info, "Tower request payload: #{payload.inspect}") if (@DEBUG and !payload.nil?)

            # call the Ansible Tower REST service
            begin
              response = RestClient::Request.new(params).execute
            rescue => e
              error("Error making Tower request: #{e.response}")
            end

            # Parse Tower Response
            response_json = {}  
            # treat all 2xx responses as acceptable
            if response.code.to_s =~ /2\d\d/
              response_json = JSON.parse(response) unless response.body.blank?
            else
              error("Error calling Ansible Tower REST API. Response Code: <#{response.code}>  Response: <#{response.inspect}>")
            end
            return response_json
          end

          def main 

            @handle.log(:info, "Starting Ansible Tower REST API call to add a host to the inventory")
                        
            dump_root()    if @DEBUG
            
            check_configuration

            # Get Ansible Tower Inventory ID from Inventory Name
            inventory_name = @tower_config['tower_inventory_name']
            error('Ansible Tower Inventory not defined. Update configuration at #{@tower_config.name}') if inventory_name.blank?
            @handle.log(:info, "inventory_name: #{inventory_name}") if @DEBUG
            api_path = "inventories?name=#{CGI.escape(inventory_name)}"
            inventory_result = tower_request(:get, api_path)
            inventory_id = inventory_result['results'].first['id'] rescue nil
            error("Unable to determine Tower inventory_id from inventory name: [ #{inventory_name} ]") if inventory_id.blank?
            @handle.log(:info, "inventory_id: #{inventory_id}") if @DEBUG

            # Get VM ip address and hostname
            vm,options = get_vm_and_options()
            error('Unable to find VM') if vm.blank?
            # determine vm hostname, first try to get hostname entry, else use vm name
            vm_hostname   = vm.hostnames.first unless vm.hostnames.blank?
            vm_hostname ||= vm.name
            @handle.log(:info, "VM Hostname determined for Ansible Tower Inventory: #{vm_hostname}") if @DEBUG
            error('Unable to determine vm_name') if vm_hostname.blank?
            error('No IP addresses associated with VM') if vm.ipaddresses.blank?
            vm_ip_address = vm.ipaddresses.first
            @handle.log(:info, "Host IP address to be added to Tower Inventory: #{vm_ip_address}") if @DEBUG

            # Check if VM already exists in inventory
            api_path = "inventories/#{inventory_id}/hosts/?name=#{vm_hostname}"
            host_result = tower_request(:get, api_path)
            host_present_in_inventory = host_result['count'] > 0
            host_id = host_result['results'].first['id'] if host_present_in_inventory
            @handle.log(:info, "Host already present in Tower inventory: Host ID = #{host_id}") if ( @DEBUG and host_present_in_inventory )
            @handle.log(:info, "Host not yet present in Tower inventory") if ( @DEBUG and !host_present_in_inventory )

            # Add the host to Ansible Tower Inventory
            api_path = host_present_in_inventory ? "hosts/#{host_id}" : "hosts"
            host_management_action = host_present_in_inventory ? :patch : :post

            host_variables = {
              :ansible_host => vm_ip_address
              }.to_json

            payload = {
              :name      => vm_hostname,
              :inventory => inventory_id,
              :enabled   => true,
              :variables => host_variables
              }.to_json

            tower_request(host_management_action, api_path, payload)

            # Verify if the name is in the inventory now.
            api_path = "inventories/#{inventory_id}/hosts?name=#{vm_hostname}"
            host_added_result = tower_request(:get, api_path)
            if host_added_result['count'] == 0
              error("Failed to add #{vm_hostname} to Ansible Inventory [ #{inventory_name} ].")
            end
            @handle.log(:info, "VM #{vm_hostname} with IP address #{vm_ip_address} successfully added to Ansible Tower inventory [ #{inventory_name} ]")
            exit MIQ_OK
          end
          
        end
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  AutomationManagement::AnsibleTower::Operations::Methods::AddHostToInventory.new.main
end
