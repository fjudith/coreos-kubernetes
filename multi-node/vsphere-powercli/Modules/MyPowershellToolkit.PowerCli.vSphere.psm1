Function Update-Coreos{
    PARAM(
        [parameter(mandatory=$false,position=0)]
        [string]
        $UpdateChannel = 'stable',

        [parameter(mandatory=$false,position=1)]
        [string]
        $Destination = "$(pwd)\.ova\coreos_production_vmware_ova.ova"
    )
    BEGIN{
        Import-Module BitsTransfer

        # Download URL
        $URI = "https://${UpdateChannel}.release.core-os.net/amd64-usr/current/coreos_production_vmware_ova.ova"
        $Digests = "https://${UpdateChannel}.release.core-os.net/amd64-usr/current/coreos_production_vmware_ova.DIGESTS"
    }
    PROCESS{
        # Test if OVA already downloaded
        If(Test-Path $Destination){
            # If Already exists then
            # Compute MD5 Hash of the current file to determine if udpate is required
            $Md5 = New-Object -TypeName System.Security.Cryptography.MD5CryptoServiceProvider

            $Hash = [System.BitConverter]::ToString($Md5.ComputeHash([System.IO.File]::ReadAllBytes($Destination))) -Replace "-",""

            $Compare = Invoke-WebRequest -Method 'GET' -URI $Digests

            Write-Host -NoNewline -Object "CoreOS OVA `"$UpdateChannel`" status ["
            If($Compare.RawContent -Match $Hash){
                Write-Host -NoNewLine -ForegroundColor 'green' -Object "Up-To-Date"
                Write-Host -Object "]"
            }
            Else{
                Write-Host -NoNewLine -ForegroundColor 'yellow' -Object "Updating"
                Write-Host -Object "]"

                Remove-Item -Force -Path $Destination

                #Invoke-WebRequest -Uri $URI -OutFile $Destination
                Start-BitsTransfer -Source $URI -Destination $Destination
            }        
        }
        Else{
            # If not exists then
            # Create desitnation directory and download file
            Write-Host -NoNewLine -ForegroundColor 'magenta' -Object "Downloading"
            Write-Host -Object "]"

            New-Item -Force -ItemType 'Directory' -Path  $([System.IO.FileInfo]$OVAPath).DirectoryName
            Invoke-WebRequest -Uri $URI -OutFile $OVAPath
        }

    }

}



Function Import-CoreOS{
    PARAM(
        [parameter(mandatory=$false,position=1)]
        [string]
        $Name,

        [parameter(mandatory=$false,position=2)]
        [string]
        $Datastore,

        [parameter(mandatory=$false)]
        [string]
        $VMHost,

        [parameter(mandatory=$false)]
        [string]
        $Cluster,

        [parameter(mandatory=$false)]
        [string]
        $PortGroup,
        
        [parameter(mandatory=$false)]
        [string]
        $DiskStorageFormat = 'thin',

        [parameter(mandatory=$false)]
        [string]
        $OVAPath = "${pwd}\.ova\coreos_production_vmware_ova.ova"

    )
    BEGIN{
        Import-Module -Force -Name 'VMware.VimAutomation.Core'

        If(-Not $(Test-Path -Path $OVAPath)){
            Update-CoreOS
        }
    }
    PROCESS{
        # Import OVA in VMHost
        If($VMHost){
            $VMHostObject = Get-VMHost -Name $VMHost
            
        }
        Elseif($Cluster){
            $ClusterHosts = Get-cluster -Name "${Cluster}" | Get-VMHost
            $Rand = Get-Random -Minimum 0 -Maximum ($ClusterHosts.Length -1)
            
            Write-Host -NoNewLine -Object "${Name}: Elected cluster host ["
            Write-Host -NoNewLine -ForegroundColor 'green' -Object "$($($ClusterHosts)[$Rand].Name)"
            Write-Host -Object "]"
            
            $VMHostObject = Get-VMHost -Name $($($ClusterHosts)[$Rand].Name)
        }
        
        $Datastore = Get-Datastore -Name $Datastore
        $VMHostObject | Import-vApp -Source $OVAPath -Name $Name -DataStore $Datastore -DiskStorageFormat $DiskStorageFormat > $Null

        # Distables vApp/Ovfenv if connected to a vCenter instance as CoreOS OVA computes "ovfenv" first.
        If($(Get-VMHost).Length -gt 1){
            # Connecté à un vCenter
            # Désactivation de l'option vApp
            $disablespec = New-Object VMware.Vim.VirtualMachineConfigSpec
            $disablespec.vAppConfigRemoved = $True

            $VM = Get-VM $Name | Get-View
            $VM.ReconfigVM($disablespec)
        }
        
        # Assign Portgroup to network interface
        $NetWorkAdapters = Get-VMHost -Name $VMHostObject | Get-VM -Name $Name | Get-NetworkAdapter -Name 'Network Adapter 1'
        $PortGroupObject = Get-VMHost -Name $VMHostObject | Get-VirtualPortGroup -Name $PortGroup
        Set-NetworkAdapter -NetworkAdapter $NetWorkAdapters -Portgroup $PortGroupObject -Confirm:$False > $Null
    }
}

Function Write-CoreOSCloudConfig{
    PARAM(
        [parameter(mandatory=$false,position=0)]
        [string]
        $Name,  

        [parameter(mandatory=$false,position=1)]
        [hashtable]
        $GuestInfo, 

        [parameter(mandatory=$false,position=2)]
        [string]
        $CloudConfigPath,

        [parameter(mandatory=$false)]
        [string]
        $Cluster,

        [parameter(mandatory=$false)]
        [string]
        $VMHost
    )
    BEGIN{
        
        # Temporary VMX file to inject cloud-config data
        $vmxTemp = "$($([System.IO.FileInfo]$CloudConfigPath).DirectoryName)\$($Name).vmx"

        # Convert cloud-config data to Base-64 for VMX injection
        $cc = Get-Content -Path "${CloudConfigPath}" -Raw
        $b = [System.Text.Encoding]::UTF8.GetBytes($cc)
        $EncodedText = [System.Convert]::ToBase64String($b)
        #$EncodedText = & "C:\Program Files\Git\usr\bin\base64.exe" -w0 "$CloudConfigPath"

        # Get virtual machine object
        If($Cluster)    {$vm = Get-Cluster -Name $Cluster | Get-VM -Name $Name}
        ElseIf($VMHost) {$vm = Get-VMHost -Name $VMHost | Get-VM -Name $Name}
        Else            {$vm = Get-VM -Name $Name}
    }
    PROCESS{

        # Power-Off the virtualmachine if powered-on.
        If ($vm.PowerState -eq "PoweredOn"){ $vm | Stop-VM -Confirm:$False }

        # VMX file download from vSphere infrastructure
        $Datastore = $vm | Get-Datastore
        $vmxRemote = "$($Datastore.name):\$($Name)\$($Name).vmx"

        If (Get-PSDrive | Where-Object { $_.Name -eq $Datastore.Name}) { Remove-PSDrive -Name $Datastore.Name }
        
        New-PSDrive -Location $Datastore -Name $Datastore.Name -PSProvider VimDatastore -Root "\" > $Null
        Copy-DatastoreItem -Item $vmxRemote -Destination $vmxTemp > $Null

        # Cleanup existing guestinfo.coreos.config.* data
        $vmx = $($(Get-Content $vmxTemp | Select-String -Pattern 'guestinfo.coreos.config.data' -NotMatch) -join "`n").Trim()
        $vmx = $(($vmx | Select-String -Pattern 'guestinfo.coreos.config.data.encoding' -NotMatch) -join "`n").Trim()
        $vmx += "`n"

        # Inject new cloud-config data
        $vmx += "guestinfo.coreos.config.data = $EncodedText" + "`n"
        $vmx += "guestinfo.coreos.config.data.encoding = base64" + "`n"
        
        $GuestInfo.Keys | ForEach-Object{
            $vmx += "$($_) = $($GuestInfo[$_])" + "`n"

        }

        # Save new configuration in temporary VMX file
        $vmx | Out-File $vmxTemp -Encoding 'ASCII'

        # Replace vSphere Infrastructure VMX file with temporary one
        Copy-DatastoreItem -Item $vmxTemp -Destination $vmxRemote

        # Power-On virtaul machine and watch for VMware Tools status
        $vm | Start-VM > $Null
        $status = "toolsNotRunning"
        while ($status -eq "toolsNotRunning")
        {
            Start-Sleep -Seconds 1
            $status = (Get-VM -name $Name | Get-View).Guest.ToolsStatus
            
            Write-Host -NoNewline -Object "${Name}: VMware Tools Status [" 
            Write-Host -NoNewline -ForegroundColor 'yellow' -Object $Status
            Write-Host -Object "]" 
        }
    }
    END {
        Write-Host -NoNewline -Object "${Name}: VMware Tools Status [" 
        Write-Host -NoNewline -ForegroundColor 'green' -Object $Status
        Write-Host -Object "]" 

        Remove-PSDrive -Name $Datastore.Name > $Null
    }
}