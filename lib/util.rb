def get_provider
  provider_index = ARGV.index('--provider')
  if (provider_index && ARGV[provider_index + 1])
     return ARGV[provider_index + 1]
  elsif ARGV.index('--provider=lxc')
     return "lxc"
  end
  return ENV['VAGRANT_DEFAULT_PROVIDER'] || 'virtualbox'
end

$provider = get_provider().to_sym

class VagrantPlugins::ProviderVirtualBox::Action::SetName
  alias_method :original_call, :call
  def call(env)
    machine = env[:machine]
    driver = machine.provider.driver
    uuid = driver.instance_eval { @uuid }
    ui = env[:ui]

    controller_name="SATA Controller"

    vm_info = driver.execute("showvminfo", uuid)
    controller_already_exists = vm_info.match("Storage Controller Name.*#{controller_name}")

    if controller_already_exists
      ui.info "already has the #{controller_name} hdd controller, skipping creation/add"
    else
      ui.info "creating #{controller_name} hdd controller"
      driver.execute(
        'storagectl',
        uuid,
        '--name', "#{controller_name}",
        '--add', 'sata',
        '--controller', 'IntelAHCI')
    end

    original_call(env)
  end
end

# Add persistent storage volumes
def attach_volumes(node, disk_sizes)
  if $provider == :virtualbox
    node.vm.provider :virtualbox do |v, override|
      disk_num = 0
      disk_sizes.each do |disk_size|
        disk_num += 1
        diskname = File.join(File.dirname(File.expand_path(__FILE__)), ".virtualbox", "#{node.vm.hostname}-#{disk_num}.vdi")
        unless File.exist?(diskname)
          v.customize ['createhd', '--filename', diskname, '--size', disk_size * 1024]
        end
        v.customize ['storageattach', :id, '--storagectl', 'SATA Controller', '--port', disk_num, '--device', 0, '--type', 'hdd', '--medium', diskname]
      end
    end
  end

  if $provider == :vmware_fusion
    node.vm.provider :vmware_fusion do |v, override|
      vdiskmanager = '/Applications/VMware\ Fusion.app/Contents/Library/vmware-vdiskmanager'
      unless File.exist?(vdiskmanager)
        dir = File.join(File.dirname(File.expand_path(__FILE__)), ".vmware")
        unless File.directory?( dir )
          Dir.mkdir dir
        end

        disk_num = 0
        disk_sizes.each do |disk_size|
          disk_num += 1
          diskname = File.join(dir, "#{node.vm.hostname}-#{disk_num}.vmdk")
          unless File.exist?(diskname)
            `#{vdiskmanager} -c -s #{disk_size}GB -a lsilogic -t 1 #{diskname}`
          end

          v.vmx["scsi0:#{disk_num}.filename"] = diskname
          v.vmx["scsi0:#{disk_num}.present"] = 'TRUE'
          v.vmx["scsi0:#{disk_num}.redo"] = ''
        end
      end
    end
  end

  if $provider == :parallels
    node.vm.provider :parallels do |v, override|
      disk_sizes.each do |disk_size|
        v.customize ['set', :id, '--device-add', 'hdd', '--size', disk_size * 1024]
      end
    end
  end

end

