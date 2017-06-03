Function Write-K8sCACertificate{
    PARAM(
        [parameter(mandatory=$True)]
        [String]
        $OutputPath
    )
    BEGIN{
        $ErrorActionPreference = 'stop'

        $OpenSSLBinary = $(Get-Command -Type 'Application' -Name 'openssl').Path

        If(-not $(Test-Path -Path $OutputPath)){throw "Output directory path:`"$OutputPath`" does not exists."}

        $PEMFile = "${OutputPath}\ca.pem"
        $KeyFile    = "${OutputPath}\ca-key.pem"
        
        if(Test-Path -Path $PEMFile){
            Write-Verbose -Message "CA Certificate already exists. Nothing to do."
            Break
        }   
    }
    PROCESS{
        # Generate private key
        Write-Verbose -Message "Generating CA certificate private key path:`"$KeyFile`""
        $Log = "${KeyFile}.log"
        
        Start-Process -ErrorAction 'Stop' -Wait -WorkingDirectory $pwd -FilePath $OpenSSLBinary -ArgumentList (
            "genrsa",
            "-out",
            "`"${KeyFile}`"",
            "2048"
        ) -NoNewWindow -RedirectStandardOutput $Log

        # Generate Certificate
        Write-Verbose -Message "Generating certificate path:`"$PEMFile`""
        
        $Log = "${PEMFile}.log"

        Start-Process -ErrorAction 'Stop' -Wait -WorkingDirectory $pwd -FilePath $OpenSSLBinary -ArgumentList (
            "req",
            "-x509",
            "-new",
            "-nodes",
            "-key `"${KeyFile}`"",
            "-days 10000",
            "-out `"$PEMFile`"",
            "-subj `"/CN=kube-ca`""
        ) -NoNewWindow -RedirectStandardOutput $Log
    }
    END{
        Write-Output -InputObject $(Get-ChildItem -Path $OutputPath)
    }
}


Function Write-K8sCertificate{
    PARAM(
        [parameter(mandatory=$True)]
        [String]
        $OutputPath,
        
        [parameter(mandatory=$True)]
        [String]
        $Name,
        
        [parameter(mandatory=$True)]
        [String]
        $CommonName,
        
        [parameter(mandatory=$False)]
        [String[]]
        $SubjectAlternativeName
    )
    BEGIN{
        $ErrorActionPreference = 'stop'

        $OpenSSLBinary = $(Get-Command -Type 'Application' -Name 'openssl').Path

        If(-not $(Test-Path -Path $OutputPath)){throw "Output directory path:`"$OutputPath`" does not exists."}

        $OutputFile = "${OutputPath}\$CommonName.zip"

        if(Test-Path -Path $OutputFile){
            Write-Verbose -Message "Certificate package for `"$CommonName`" already exists. Nothing to do."
            Break
        }

        $CNFTemplate = "[req]
    req_extensions = v3_req
    distinguished_name = req_distinguished_name

    [req_distinguished_name]

    [ v3_req ]
    basicConstraints = CA:FALSE
    keyUsage = nonRepudiation, digitalSignature, keyEncipherment
    subjectAltName = @alt_names

    [alt_names]
    DNS.1 = kubernetes
    DNS.2 = kubernetes.default
    DNS.3 = kubernetes.default.svc
    DNS.4 = kubernetes.default.svc.cluster.local"

        $ConfigFile="${OutputPath}\${Name}-req.cnf"
        $CAFile="${OutputPath}\ca.pem"
        $CAKeyFile="${OutputPath}\ca-key.pem"
        $KeyFile="${OutputPath}\${Name}-key.pem"
        $CSRFile="${OutputPath}\${Name}.csr"
        $PEMFile="${OutputPath}\${Name}.pem"

        $Contents="${CAFile} ${KeyFile} ${PEMFile}"
    }
    PROCESS{
        
        # Add SANs to openssl config
        Write-Verbose -Message "Adding Suject Alternative Names:`"$SubjectAlternativeName`" to OpenSSL configuration file path:`"$ConfigFile`""
        Add-Content -Path $ConfigFile -Value $CNFTemplate
        Add-Content -Path $ConfigFile -Value $SubjectAlternativeName

        # Generate private key
        Write-Verbose -Message "Generating certificate private key path:`"$KeyFile`" for `"$Name`""
        
        $Log = "${KeyFile}.log"
        
        Start-Process -RedirectStandardOutput $Log -ErrorAction 'Stop' -Wait -WorkingDirectory $pwd -FilePath $OpenSSLBinary -ArgumentList (
            "genrsa",
            "-out",
            "`"$KeyFile`"",
            "2048"
        ) -NoNewWindow

        # Generate CSR
        Write-Verbose -Message "Generating certificate request path:`"$CSRFile`" for `"$Name`""

        $Log = "${CSRFile}.log"

        Start-Process -RedirectStandardOutput $Log -ErrorAction 'Stop' -Wait -WorkingDirectory $pwd -FilePath $OpenSSLBinary -ArgumentList (
            "req",
            "-new",
            "-key `"$KeyFile`"",
            "-out `"$CSRFile`"",
            "-subj `"/CN=$CommonName`"",
            "-config `"$ConfigFile`""
        ) -NoNewWindow

        # Generate Certificate
        Write-Verbose -Message "Generating certificate path:`"$PEMFile`" for `"$Name`""

        $Log = "${PEMFile}.log"

        Start-Process -RedirectStandardOutput $Log  -ErrorAction 'Stop' -Wait -WorkingDirectory $pwd -FilePath $OpenSSLBinary -ArgumentList (
            "x509",
            "-req",
            "-in `"$CSRFile`"",
            "-CA `"$CAFile`"",
            "-CAkey `"$CAKeyFile`"",
            "-CAcreateserial",
            "-out `"$PEMFile`"",
            "-days 365",
            "-extensions v3_req",
            "-extfile `"$ConfigFile`""
        ) -NoNewWindow

        # Packing output files to Zip
        Compress-Archive -DestinationPath $OutputFile -Path @(
            $(Get-Item -Path $CAFile).FullName,
            $(Get-Item -Path $KeyFile).FullName,
            $(Get-Item -Path $PEMFile).FullName
        )
    }
}

Function Send-SSHMachineSSL{
    PARAM(
        [parameter(mandatory=$true)]
        [string]
        $Machine,
        
        [parameter(mandatory=$true)]
        [string]
        $CertificateBaseName, 
        
        [parameter(mandatory=$true)]
        [String]
        $CommonName, 
        
        [parameter(mandatory=$true)]
        [String[]]
        $IpAddresses,
        
        [parameter(mandatory=$true)]
        [String]
        $Computername,
    
        [parameter(mandatory=$false)]
        [PSCredential]
        $Credential,

        [parameter(mandatory=$true)]
        [int]
        $SSHSession
    )
    BEGIN{
        $ZipFile = "${pwd}/${CommonName}.zip"
        $IPString = @()
        For($i = 0 ; $i -lt $IpAddresses.Length; $i++){$IPString += "IP.$($i +1) = $($IpAddresses[$i])"}
    }
    PROCESS{
        Write-K8sCertificate -OutputPath "${pwd}\ssl" -Name "${CertificateBaseName}" -CommonName "${CommonName}" -SubjectAlternativeName $IpString

        Set-ScpFile  -Force -LocalFile $ZipFile -RemotePath '/tmp/' -ComputerName $Computername -Credential $Credential
        Invoke-SSHCommand -SessionId $SSHSession -Command "sudo mkdir -p /etc/kubernetes/ssl && sudo unzip -o -e /tmp/${CommonName}.zip -d /etc/kubernetes/ssl"
    }
}

Function Update-Coreos{
    PARAM(
        [parameter(mandatory=$false,position=0)]
        [string]
        $UpdateChannel = 'stable',

        [parameter(mandatory=$false,position=1)]
        [string]
        $Destination = "${pwd}\.ova\coreos_production_vmware_ova.ova"
    )
    BEGIN{
        Import-Module BitsTransfer

        # Download URL
        $URI = "https://${UpdateChannel}.release.core-os.net/amd64-usr/current/coreos_production_vmware_ova.ova"
        $Digests = "https://${UpdateChannel}.release.core-os.net/amd64-usr/current/coreos_production_vmware_ova.DIGESTS"

        # Test Internet Access
        Write-Host -NoNewline -Object "Internet access status ["
        Try{
            Invoke-WebRequest -URI "https://${UpdateChannel}.release.core-os.net" > $Null
            Write-Host -NoNewline -ForegroundColor 'green' -Object 'Connected'
        }
        Catch{
            Write-Host -NoNewline -ForegroundColor 'red' -Object 'Not Connected'
        }
        Write-Host -Object "]"
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

                
                Start-BitsTransfer -Source $URI -Destination $Destination
            }        
        }
        Else{
            # If not exists then
            # Create desitnation directory and download file
            Write-Host -NoNewLine -Object "CoreOS OVA `"$UpdateChannel`" status ["
            Write-Host -NoNewLine -ForegroundColor 'Yellow' -Object "Downloading"
            Write-Host -Object "]"

            New-Item -Force -ItemType 'Directory' -Path  $([System.IO.FileInfo]$Destination).DirectoryName > $Null
            Invoke-WebRequest -Uri $URI -OutFile $Destination
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
        Import-Module -Name 'VMware.VimAutomation.Core'

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
            
            Write-Host -NoNewLine -Object "${Name}: Selected vSphere host ["
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
        Copy-DatastoreItem -Force -Item $vmxTemp -Destination $vmxRemote

        # Power-On virtaul machine and watch for VMware Tools status
        $vm | Start-VM > $Null
        $status = "toolsNotRunning"
        while ($status -eq "toolsNotRunning"){
            $status = (Get-VM -name $Name | Get-View).Guest.ToolsStatus
            
            Write-Host -NoNewline -Object "${Name}: VMware Tools Status [" 
            Write-Host -NoNewline -ForegroundColor 'yellow' -Object $Status
            Write-Host -Object "]"

            Start-Sleep -Seconds 10
        }
    }
    END {
        Write-Host -NoNewline -Object "${Name}: VMware Tools Status [" 
        Write-Host -NoNewline -ForegroundColor 'green' -Object $Status
        Write-Host -Object "]"

        Remove-PSDrive -Name $Datastore.Name > $Null
    }
}


Function New-K8sIpAddress{
<#
.SYNOPSIS
Compute an IPv4 address for a host.

.DESCRIPTION
Returns an IPv4 address for any of the Kubernetes hosts (i.e. etcd, controller, worker).

.PARAMETER Subnet
Specifies the IPv4 subnet where the host will be allocated.

.PARAMETER StartFrom
Specifies the number representing the last octet of the ip address.

.PARAMETER Count
Specifies the number that will be added to the last octet of the ip address (i.e. StartFrom parameter)

.EXAMPLE
Specifies the number

.NOTES
General notes
#>
    PARAM(
        [parameter(mandatory=$true)]
        [String]
        $Subnet,

        [parameter(manadatory=$true)]
        [String]
        $StartFrom = '50',

        [parameter(mandatory=$false)]
        [Int]
        $Count
    )
    PROCESS{
        # Parse Subnet address to extract the first 3 octets
        $Subnet -Match '^(?<BeginIP>\d{1,3}\.\d{1,3}\.\d{1,3})\.\d{1,3}$' > $Null

        Write-Output -InputObject "$($Matches.BeginIP).$($Count + $StartFrom)"
    }
}


Function Get-K8sEtcdIP{
    PARAM(
        [parameter(mandatory=$false)]
        [string]
        $Subnet,
        
        [parameter(mandatory=$false)]
        [int]
        $StartFrom = '50',

        [parameter(mandatory=$false)]
        [int]
        $Count = '1'
    )
    BEGIN{
        $IpArray = @()
    }
    PROCESS{
        For($i = 1 ; $i -le $Count; $i++){
            $IpArray += New-K8sIpAddress -Subnet $Subnet -StartFrom $StartFrom -Count $i
        }
    }
    End{
        Write-Verbose "etcd IP:`"$ClusterArray`""

        # Return the array containing the etcd ip address list
        Write-Output -InputObject $IpArray
    }
}

Function Get-K8sEtcdInitialCluster{
    PARAM(
        [paramter(mandatory=$false)]
        [string]
        $NamePrefix = 'etcd',

        [parameter(mandatory=$false)]
        [string[]]
        $IpAddress
    )
    BEGIN{
        $ClusterArray = @()
    }
    PROCESS{
        For($i = 0 ; $i -le $IpAdress.Length; $i++){
            $ClusterArray += "${NamePrefix}$("{0:D3}" -f $($i +1))=http://$($EtcdIPs[$i]):2380"
        }
    }
    End{
        # Flatten the array with comma separators
        $ClusterArray = $ClusterArray -Join ','
        Write-Verbose "Initial Etcd Cluster:`"$ClusterArray`""

        # Return the array containing the etcd ip address list
        Write-Output -InputObject $ClusterArray
    }
}

Function Get-K8sEtcdEndpoint{
    PARAM(
        [parameter(mandatory=$false)]
        [string[]]
        $IpAddress,

        [parameter(mandatory=$false)]
        [string]
        $Protocol = 'http',

        [paramter(mandatory=$false)]
        [int]
        $port = '2379'
    )
    BEGIN{
        $ClusterArray = @()
    }
    PROCESS{
        Foreach($Item in $IpAddress){
            $ClusterArray += "${Protocol}://${Item}:${Port}"
        }
    }
    End{
        # Flatten the array with comma separators
        $ClusterArray = $ClusterArray -Join ','
        Write-Verbose "Etcd endpoints:`"$ClusterArray`""

        # Return the array containing the etcd ip address list
        Write-Output -InputObject $ClusterArray
    }
}

Function Get-K8sControllerIP{
    PARAM(
        [parameter(mandatory=$false)]
        [string]
        $Subnet,
        
        [parameter(mandatory=$false)]
        [int]
        $StartFrom = '100',

        [parameter(mandatory=$false)]
        [int]
        $Count = '1',
        
        [parameter(mandatory=$false)]
        [string]
        $ControllerCluser = '10.3.0.1'
    )
    BEGIN{
        $IpArray = @()
    }
    PROCESS{
        For($i = 1 ; $i -le $Count; $i++){
            $IpArray += New-K8sIpAddress -Subnet $Subnet -StartFrom $StartFrom -Count $i
        }
    }
    End{
        $IpArray += $ControllerCluser
        Write-Verbose "Conroller IP:`"$ClusterArray`""

        # Return the array containing the controller ip address list
        Write-Output -InputObject $IpArray
    }
}


Function New-K8sEtcdCluster{
    PARAM(
        [parameter(mandatory=$false)]
        [string]
        $Subnet,

        [parameter(mandatory=$false)]
        [int]
        $CIDR,

        [parameter(mandatory=$false)]
        [string]
        $Gateway,
        
        [parameter(mandatory=$false)]
        [string[]]
        $DNS,

        [parameter(mandatory=$false)]
        [int]
        $StartFrom = '50',

        [parameter(mandatory=$false)]
        [int]
        $Count = '1',

        [parameter(mandatory=$false)]
        [string]
        $NamePrefix = 'etcd',

        [parameter(mandatory=$false)]
        [string]
        $VMHost,
        
        [parameter(mandatory=$false)]
        [string]
        $Cluster,

        [parameter(mandatory=$false)]
        [string]
        $DataStore = 'datastore1',

        [parameter(mandatory=$false)]
        [string]
        $PortGroup = 'VM Network',

        [parameter(mandatory=$false)]
        [string]
        $DiskstorageFormat = 'thin',

        [parameter(mandatory=$false)]
        [string]
        $CloudConfigFile = "${pwd}\etcd-cloud-config.yaml"
    )
    BEGIN{
        Write-Verbose -Message "Provisionning `"${Count}`" etcd hosts"

        $IpAddresses = New-K8sIpAddress -Subnet $Subnet -StartFrom $StartFrom -Count $Count
        $EtcdCluster = Get-K8sEtcdInitialCluster -NamePrefix $NamePrefix -IpAddress $IpAddresses
    }
    PROCESS{
        For($i = 0; $i -lt $Count; $i++){
            $Name = "${NamePrefix}$("{0:D3}" -f $($i +1))"
            $IP = New-K8sIpAddress -Subnet $Subnet -StartFrom $StartFrom -Count $($i +1)
            
            $ConfigPath = "${pwd}\conf\etcd\$Name\openstack\latest\user-data"

            New-Item -Force -ItemType 'Directory' -Path $(([System.IO.fileInfo]$ConfigPath).DirectoryName) > $Null

            $Config = $(Get-Content -Path "${pwd}\${$CloudConfigFile}") -Replace '\{\{ETCD_NODE_NAME\}\}',$Name
            $Config = $Config -Replace '\{\{ETCD_INITIAL_CLUSTER\}\}',$EtcdCluster
            Set-Content -Path $ConfigPath -Value $Config

            $GuestInfo = @{
                'guestinfo.hostname' = "${Name}";
                'guestinfo.interface.0.name' = 'ens192';
                'guestinfo.interface.0.dhcp' = 'no';
                'guestinfo.interface.0.role' = 'private';
                'guestinfo.interface.0.ip.0.address' = "${IP}/${CIDR}";
                'guestinfo.interface.0.route.0.gateway' = "${Gateway}";
                'guestinfo.interface.0.route.0.destination' = '0.0.0.0/0'
            }

            # Add DNS records to GuestInfo
            For( $i = 0; $i -le $DNS.Length ; $i++){
                $GuestInfo += @{"guestinfo.dns.server.$($i)" = $DNS[$i]}
            }

            # Provision, Configure and Start VM
            If($VMHost -and $Cluster){
                Throw "Processing VMhost and Cluster is not supported"
            }
            ElseIf($VMHost){
                Import-CoreOS -Name "${Name}" -DataStore "${DataStore}" -VMHost "${VMHost}" -PortGroup "${PortGroup}" -DiskStorageFormat "${DiskstorageFormat}"
                Write-CoreOSCloudConfig -Name "${Name}" -GuestInfo $GuestInfo -CloudConfigPath "${ConfigPath}" -VMHost "${VMHost}"
            }
            ElseIf($Cluster){
                Import-CoreOS -Name "${Name}" -DataStore "${DataStore}" -Cluster "${Cluster}" -PortGroup "${PortGroup}" -DiskStorageFormat "${DiskstorageFormat}"
                Write-CoreOSCloudConfig -Name "${Name}" -GuestInfo $GuestInfo -CloudConfigPath "${ConfigPath}" -Cluster "${Cluster}"               
            }
            Else{
                Throw "Missing vSphere hosting agurment:`"-VMHost`" or `"-Cluster`""
            }
        }
    }

}


Function New-K8sControllerCluster{
    PARAM(
        [parameter(mandatory=$false)]
        [string]
        $Subnet,

        [parameter(mandatory=$false)]
        [int]
        $CIDR,

        [parameter(mandatory=$false)]
        [string]
        $Gateway,
        
        [parameter(mandatory=$false)]
        [string[]]
        $DNS,

        [parameter(mandatory=$false)]
        [int]
        $StartFrom = '100',

        [parameter(mandatory=$false)]
        [int]
        $Count = '1',

        [parameter(mandatory=$false)]
        [string]
        $NamePrefix = 'ctrl',

        [parameter(mandatory=$false)]
        [string]
        $VMHost,
        
        [parameter(mandatory=$false)]
        [string]
        $Cluster,

        [parameter(mandatory=$false)]
        [string]
        $DataStore = 'datastore1',

        [parameter(mandatory=$false)]
        [string]
        $PortGroup = 'VM Network',

        [parameter(mandatory=$false)]
        [string]
        $DiskstorageFormat = 'thin',

        [parameter(mandatory=$false)]
        [string]
        $CloudConfigFile = "${pwd}\Controller-cloud-config.yaml",
        
        [parameter(mandatory=$false)]
        [PSCredential]
        $Credential,

        [parameter(mandatory=$false)]
        [string]
        $InstallScript
    )
    BEGIN{
        Write-Verbose -Message "Provisionning `"${Count}`" controller hosts"

        $IpAddresses = New-K8sIpAddress -Subnet $Subnet -StartFrom $StartFrom -Count $Count
    }
    PROCESS{
        For($i = 0; $i -lt $Count; $i++){
            $Name = "${NamePrefix}$("{0:D3}" -f $($i +1))"
            $IP = New-K8sIpAddress -Subnet $Subnet -StartFrom $StartFrom -Count $($i +1)

            # Cloud Config
            $ConfigPath = "${pwd}\conf\controller\$Name\openstack\latest\user-data"
            New-Item -Force -ItemType 'Directory' -Path $(([System.IO.fileInfo]$ConfigPath).DirectoryName) > $Null
            $Config = Get-Content -Path "${CloudConfigFile}"
            $Config = $Config -Replace '\{\{ETCD_ENDPOINTS\}\}',$EtcdEndpoints
            Set-Content -Path $ConfigPath -Value $Config

            $GuestInfo = @{
                'guestinfo.hostname' = "${Name}";
                'guestinfo.interface.0.name' = 'ens192';
                'guestinfo.interface.0.dhcp' = 'no';
                'guestinfo.interface.0.role' = 'private';
                'guestinfo.interface.0.ip.0.address' = "${IP}/${CIDR}";
                'guestinfo.interface.0.route.0.gateway' = "${Gateway}";
                'guestinfo.interface.0.route.0.destination' = '0.0.0.0/0'
            }
            
            # Add DNS records to GuestInfo
            For( $i = 0; $i -le $DNS.Length ; $i++){
                $GuestInfo += @{"guestinfo.dns.server.$($i)" = $DNS[$i]}
            }

            # Provision, Configure and Start VM
            If($VMHost -and $Cluster){
                Throw "Processing VMhost and Cluster is not supported"
            }
            ElseIf($VMHost){
                Import-CoreOS -Name "${Name}" -DataStore "${DataStore}" -VMHost "${VMHost}" -PortGroup "${PortGroup}" -DiskStorageFormat "${DiskstorageFormat}"
                Write-CoreOSCloudConfig -Name "${Name}" -GuestInfo $GuestInfo -CloudConfigPath "${ConfigPath}" -VMHost "${VMHost}"
            }
            ElseIf($Cluster){
                Import-CoreOS -Name "${Name}" -DataStore "${DataStore}" -Cluster "${Cluster}" -PortGroup "${PortGroup}" -DiskStorageFormat "${DiskstorageFormat}"
                Write-CoreOSCloudConfig -Name "${Name}" -GuestInfo $GuestInfo -CloudConfigPath "${ConfigPath}" -Cluster "${Cluster}"               
            }
            Else{
                Throw "Missing vSphere hosting agurment:`"-VMHost`" or `"-Cluster`""
            }

            Start-Sleep -Seconds 30

            # Open SSH Session
            $SSHSessionID = $(New-SSHSession -ComputerName $IP -Credential $SSHCredential -Force).SessionID

            # Generate and copy SSL asset
            Send-SSHMachineSSL -Machine $Name -CertificateBaseName 'apiserver' -CommonName "kube-apiserver-${IP}" -IpAddresses $IpAddresses `
            -Computername $IP -Credential $SSHCredential  -SSHSession $SSHSessionID
                    
            # Copy kubernetes worker configuration asset
            Set-ScpFile -Force -LocalFile "${InstallScript}" -RemotePath '/tmp/' -ComputerName $IP -Credential $SSHCredential
            Invoke-SSHCommand -Index $SSHSessionID -Command 'cd /tmp/ && mv controller-install.sh vsphere-user-data'
            Invoke-SSHCommand -Index $SSHSessionID -Command 'sudo mkdir -p /var/lib/coreos-vsphere && sudo mv /tmp/vsphere-user-data /var/lib/coreos-vsphere/'
            Invoke-SSHCommand -Index $SSHSessionID -Command 'sudo systemctl enable docker && sudo reboot' -ErrorAction 'silentlycontinue'

            # Close SSH Session
            Remove-SSHSession -SessionId $SSHSessionID

            # Restart VM
            $VMObject = Get-VM -Name "${Name}"
            # Restart-VM -VM $VMObject -Confirm:$False > $Null

            $Status = 'toolsNotRunning'
            while ($Status -eq 'toolsNotRunning'){
                $status = (Get-VM -name "$($VMObject.Name)" | Get-View).Guest.ToolsStatus
                
                Write-Host -NoNewline -Object "$($VMObject.Name) (Restart): VMware Tools Status [" 
                Write-Host -NoNewline -ForegroundColor 'yellow' -Object $Status
                Write-Host -Object "]"

                Start-Sleep -Seconds 10
            }
            Write-Host -NoNewline -Object "$($VMObject.Name) (Restart): VMware Tools Status [" 
            Write-Host -NoNewline -ForegroundColor 'green' -Object $Status
            Write-Host -Object "]"
        }
    }
}


Function New-K8sWorkerCluster{
    PARAM(
        [parameter(mandatory=$false)]
        [string]
        $Subnet,

        [parameter(mandatory=$false)]
        [int]
        $CIDR,

        [parameter(mandatory=$false)]
        [string]
        $Gateway,
        
        [parameter(mandatory=$false)]
        [string[]]
        $DNS,

        [parameter(mandatory=$false)]
        [int]
        $StartFrom = '200',

        [parameter(mandatory=$false)]
        [int]
        $Count = '1',

        [parameter(mandatory=$false)]
        [string]
        $NamePrefix = 'wrkr',

        [parameter(mandatory=$false)]
        [string]
        $VMHost,
        
        [parameter(mandatory=$false)]
        [string]
        $Cluster,

        [parameter(mandatory=$false)]
        [string]
        $DataStore = 'datastore1',

        [parameter(mandatory=$false)]
        [string]
        $PortGroup = 'VM Network',

        [parameter(mandatory=$false)]
        [string]
        $DiskstorageFormat = 'thin',

        [parameter(mandatory=$false)]
        [string]
        $CloudConfigFile = "${pwd}\worker-cloud-config.yaml",

        [parameter(mandatory=$false)]
        [PSCredential]
        $SSHCredential,

        [parameter(mandatory=$false)]
        [string]
        $InstallScript,

        [parameter(mandatory=$false)]
        [string]
        $EtcdEndpoints
    )
    BEGIN{
        Write-Verbose -Message "Provisionning `"${Count}`" worker hosts"
    }
    PROCESS{
        For($i = 0; $i -lt $Count; $i++){
            $Name = "${NamePrefix}$("{0:D3}" -f $($i +1))"
            $IP = Get-WorkerIP -Subnet $Subnet -Number $($i +1)

            # Cloud Config
            $ConfigPath = "${pwd}\conf\worker\$Name\openstack\latest\user-data"
            New-Item -Force -ItemType 'Directory' -Path $(([System.IO.fileInfo]$ConfigPath).DirectoryName) > $Null
            $Config = Get-Content -Path "${CloudConfigFile}"
            $Config = $Config -Replace '\{\{ETCD_ENDPOINTS\}\}',$EtcdEndpoints
            $ControllerEndpoint = $ControllerIPs | Select-Object -First 1 
            $Config = $Config -Replace '\{\{CONTROLLER_ENDPOINT\}\}',$ControllerEndpoint
            Set-Content -Path $ConfigPath -Value $Config

            $GuestInfo = @{
                'guestinfo.hostname' = "${Name}";
                'guestinfo.interface.0.name' = 'ens192';
                'guestinfo.interface.0.dhcp' = 'no';
                'guestinfo.interface.0.role' = 'private';
                'guestinfo.interface.0.ip.0.address' = "${IP}/${CIDR}";
                'guestinfo.interface.0.route.0.gateway' = "${Gateway}";
                'guestinfo.interface.0.route.0.destination' = '0.0.0.0/0'
            }
            # Add DNS records to GuestInfo
            For( $i = 0; $i -le $DNS.Length ; $i++){
                $GuestInfo += @{"guestinfo.dns.server.$($i)" = $DNS[$i]}
            }

            # Provision, Configure and Start VM
            If($VMHost -and $Cluster){
                Throw "Processing VMhost and Cluster is not supported"
            }
            ElseIf($VMHost){
                Import-CoreOS -Name "${Name}" -DataStore "${DataStore}" -VMHost "${VMHost}" -PortGroup "${PortGroup}" -DiskStorageFormat "${DiskstorageFormat}"
                Write-CoreOSCloudConfig -Name "${Name}" -GuestInfo $GuestInfo -CloudConfigPath "${ConfigPath}" -VMHost "${VMHost}"
            }
            ElseIf($Cluster){
                Import-CoreOS -Name "${Name}" -DataStore "${DataStore}" -Cluster "${Cluster}" -PortGroup "${PortGroup}" -DiskStorageFormat "${DiskstorageFormat}"
                Write-CoreOSCloudConfig -Name "${Name}" -GuestInfo $GuestInfo -CloudConfigPath "${ConfigPath}" -Cluster "${Cluster}"               
            }
            Else{
                Throw "Missing vSphere hosting agurment:`"-VMHost`" or `"-Cluster`""
            }

            Start-Sleep -Seconds 30

            # Open SSH Session
            $SSHSessionID = $(New-SSHSession -ComputerName $IP -Credential $SSHCredential -Force).SessionID

            Send-SSHMachineSSL -Machine $Name -CertificateBaseName 'worker' -CommonName "kube-worker-${IP}" -IpAddresses $IP `
            -Computername $IP -Credental $SSHCredential -SSHSession $SSHSessionID

            # Copy kubernetes worker configuration asset
            Set-ScpFile -Force -LocalFile "${CloudConfigPath}" -RemotePath '/tmp/' -ComputerName $IP -Credential $SSHCredential
            Invoke-SSHCommand -Index $SSHSessionID -Command 'cd /tmp/ && mv worker-install.sh vsphere-user-data'
            Invoke-SSHCommand -Index $SSHSessionID -Command 'sudo mkdir -p /var/lib/coreos-vsphere && sudo mv /tmp/vsphere-user-data /var/lib/coreos-vsphere/'
            Invoke-SSHCommand -Index $SSHSessionID -Command 'sudo systemctl enable docker && sudo reboot' -ErrorAction 'silentlycontinue'

            # Close SSH Session
            Remove-SSHSession -SessionId 0

            # Restart VM
            $VMObject = Get-VM -Name "${Name}"
            # Restart-VM -VM $VMObject -Confirm:$False > $Null

            $Status = 'toolsNotRunning'
            while ($Status -eq 'toolsNotRunning'){
                $status = (Get-VM -name "$($VMObject.Name)" | Get-View).Guest.ToolsStatus
                
                Write-Host -NoNewline -Object "$($VMObject.Name) (Restart): VMware Tools Status [" 
                Write-Host -NoNewline -ForegroundColor 'yellow' -Object $Status
                Write-Host -Object "]"

                Start-Sleep -Seconds 10
            }
            Write-Host -NoNewline -Object "$($VMObject.Name) (Restart): VMware Tools Status [" 
            Write-Host -NoNewline -ForegroundColor 'green' -Object $Status
            Write-Host -Object "]"
        }
    }
}