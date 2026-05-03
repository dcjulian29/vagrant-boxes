Vagrant.configure("2") do |config|
  config.vm.provider "hyperv" do |h|
    h.memory   = 1024
    h.cpus     = 2
    h.enable_checkpoints          = false
    h.enable_automatic_checkpoints = false
    h.vm_integration_services = {
      guest_service_interface: true
    }
  end
end
