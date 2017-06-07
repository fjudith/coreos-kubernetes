Function Write-K8sCACertificate
{
<#
.SYNOPSIS
Generate the SSL Certificate Authority certificate asset for Kubernetes. 

 - ca-key.pem
 - ca.pem

.DESCRIPTION
Use OpenSSL to create the SSL Certificate Authority certificate asset for Kubernetes.

.PARAMETER OutputPath
Specifies the directory where the CA private key and certicate will be written.

.EXAMPLE
PS C:\>Write-K8sCACertficate -Output Path "${pwd}\ssl"

    Directory: C:\Users\fjudith\Git\coreos-kubernetes\multi-node\vsphere-powercli\ssl

Mode                LastWriteTime         Length Name
----                -------------         ------ ----
-a----       04/06/2017     11:19           1706 ca-key.pem
-a----       04/06/2017     11:19           1112 ca.pem

This command generate the CA certifcate asset in a subdirectory named "ssl" stored in workding directory.
#>
    PARAM(
        [parameter(mandatory=$True)]
        [String]
        $OutputPath
    )
    BEGIN
    {
        $ErrorActionPreference = 'stop'

        $OpenSSLBinary = $(Get-Command -Type 'Application' -Name 'openssl').Path

        If(-not $(Test-Path -Path $OutputPath)){throw "Output directory path:`"$OutputPath`" does not exists."}

        $PEMFile = "${OutputPath}\ca.pem"
        $KeyFile    = "${OutputPath}\ca-key.pem"
        
        if(Test-Path -Path $PEMFile)
        {
            Write-Verbose -Message "CA Certificate already exists. Nothing to do."
            Break
        }   
    }
    PROCESS
    {
        # Generate private key
        Write-Verbose -Message "Generating CA certificate private key path:`"$KeyFile`""
        
        Start-Process -ErrorAction 'Stop' -Wait -WorkingDirectory $pwd -FilePath $OpenSSLBinary -ArgumentList (
            "genrsa",
            "-out",
            "`"${KeyFile}`"",
            "2048"
        ) -NoNewWindow

        # Generate Certificate
        Write-Verbose -Message "Generating certificate path:`"$PEMFile`""

        Start-Process -ErrorAction 'Stop' -Wait -WorkingDirectory $pwd -FilePath $OpenSSLBinary -ArgumentList (
            "req",
            "-x509",
            "-new",
            "-nodes",
            "-key `"${KeyFile}`"",
            "-days 10000",
            "-out `"$PEMFile`"",
            "-subj `"/CN=kube-ca`""
        ) -NoNewWindow
    }
    END
    {
        Write-Output -InputObject $(Get-ChildItem -Path $OutputPath)
    }
}


Function Write-K8sCertificate
{
<#
.SYNOPSIS
Create a Zip archive containing SSL certificate set for a Kubernetes host.

 - apiserver-key.pem
 - apiserver-req.cnf
 - apiserver.csr
 - apiserver.pem
 - kube-apiserver-CommonName.zip

.DESCRIPTION
Use OpenSSL and Compress-Archive  to create a Zip archive containing the SSL certificate set for a Kubernetes host.

.PARAMETER OutputPath
Specifies the directory where the following files will be written.
  - Private Key
  - Certificate Signing Request Template (CNF)
  - Certificate Signing Request (CSR)
  - Certificate
  - Zip archive containing the above files

.PARAMETER Name
Specifies the name used to save the certificate set.

.PARAMETER CommonName
Specifies the certificate Common Name (CN).

.PARAMETER SubjectAlternativeName
Specifies the certificate Subject Alternative Name (SAN).

.EXAMPLE
PS C:\> Write-K8sCertificate -OutputPath "${pwd}\ssl" -Name 'k8sctrl001' -CommonName 'kube-apiserver-192.168.1.51' -SubjectAlternativeName 'IP.1 = 192.168.1.51'

    Directory: C:\Users\fjudith\Git\coreos-kubernetes\multi-node\vsphere-powercli\ssl

Mode                LastWriteTime         Length Name
----                -------------         ------ ----
-a----       04/06/2017     11:32           1706 apiserver-key.pem
-a----       04/06/2017     11:32           1356 apiserver-req.cnf
-a----       04/06/2017     11:32           1150 apiserver.csr
-a----       04/06/2017     11:32           1220 apiserver.pem
-a----       04/06/2017     11:26           3380 kube-apiserver-192.168.1.51.zip

This command generates the host certifcate asset in a subdirectory named "ssl" stored in workding directory.
#>
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
    BEGIN
    {
        $ErrorActionPreference = 'stop'

        $OpenSSLBinary = $(Get-Command -Type 'Application' -Name 'openssl').Path

        If(-not $(Test-Path -Path $OutputPath)){throw "Output directory path:`"$OutputPath`" does not exists."}

        $OutputFile = "${OutputPath}\$CommonName.zip"

        if(Test-Path -Path $OutputFile)
        {
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
    PROCESS
    {
        
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
            "-subj `"/CN=${CommonName}/O=system:masters`"",
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

Function Send-SSHMachineSSL
{
<#
.SYNOPSIS
Send a Zip containing a certificate asset to the target host using SSH Copy (scp).

.DESCRIPTION
This command relies on the PoshSSH module and Write-K8sCertificate to push a Zip archive containing the certificate asset to the target host using SSH Copy Protocol (scp).
CA certificate attached to the archive must be name "ca.pem" and stored in the ".\ssl" directory.

.PARAMETER CertificateBaseName
Usually the hostname of the target machine used in the certificate creation process.

.PARAMETER CommonName
Certification common name (CN).

.PARAMETER IpAddresses
Specifies IP addresses to be added in the certificate subject alternative name (SAN).

.PARAMETER Computername
Specifies the computers target for SCP commands.

.PARAMETER Credential
Specifies a user account that has permission to perform the SSH action.

.PARAMETER SSHSession
Specifies the "New-SSHSession" session ID to be by the SSH commands.

.EXAMPLE
$SecureHostPassword = ConvertTo-SecureString "password" -AsPlainText -Force
$SSHCredential = New-Object System.Management.Automation.PSCredential ("user", $SecureHostPassword)

$SSHSessionID = $(New-SSHSession -ComputerName '192.168.1.51' -Credential $SSHCredential -Force).SessionID

Send-SSHMachineSSL -CertificateBaseName 'apiserver' -CommonName "kube-apiserver-192.168.1.51" -IpAddresses 192.168.1.51 -Computername $IP -Credential $SSHCredential  -SSHSession $SSHSessionID

This command line acheive the following tasks.
 1. Create a secure credential object
 2. Open an SSH session to a remote computer and retreive the session ID
 3. Generate and push the certificate archive to the remote computer.

.NOTES
General notes
#>
    PARAM(        
        [parameter(mandatory=$true)]
        [string]
        $CertificateBaseName, 
        
        [parameter(mandatory=$true)]
        [String]
        $CommonName, 
        
        [parameter(mandatory=$true)]
        [String[]]
        $IpAddresses,

        [parameter(mandatory=$false)]
        [String[]]
        $SubjectAlternativeName,

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
    BEGIN
    {
        $ZipFile = "${pwd}\ssl\${CommonName}.zip"
        $IPString = @()
        For($i = 0 ; $i -lt $IpAddresses.Length; $i++){$IPString += "IP.$($i +1) = $($IpAddresses[$i])"}

        For($i = 0 ; $i -lt $SubjectAlternativeName.Length; $i++){$IPString += "DNS.$($i +10) = $($($SubjectAlternativeName[$i]).Replace('https://',''))" }
    }
    PROCESS
    {
        Write-K8sCertificate -OutputPath "${pwd}\ssl" -Name "${CertificateBaseName}" -CommonName "${CommonName}" -SubjectAlternativeName $IpString

        Set-ScpFile  -Force -LocalFile $ZipFile -RemotePath '/tmp/' -ComputerName $Computername -Credential $Credential
        Invoke-SSHCommand -SessionId $SSHSession -Command "sudo mkdir -p /etc/kubernetes/ssl && sudo unzip -o -e /tmp/${CommonName}.zip -d /etc/kubernetes/ssl"
    }
}

Function Update-Coreos
{
    PARAM(
        [parameter(mandatory=$false,position=0)]
        [string]
        $UpdateChannel = 'stable',

        [parameter(mandatory=$false,position=1)]
        [string]
        $Destination = "${pwd}\.ova\coreos_production_vmware_ova.ova"
    )
    BEGIN
    {
        Import-Module BitsTransfer

        # Download URL
        $URI = "https://${UpdateChannel}.release.core-os.net/amd64-usr/current/coreos_production_vmware_ova.ova"
        $Digests = "https://${UpdateChannel}.release.core-os.net/amd64-usr/current/coreos_production_vmware_ova.DIGESTS"

        # Test Internet Access
        Write-Host -NoNewline -Object "Internet access status ["
        Try
        {
            Invoke-WebRequest -URI "https://${UpdateChannel}.release.core-os.net" > $Null
            Write-Host -NoNewline -ForegroundColor 'green' -Object 'Connected'
        }
        Catch
        {
            Write-Host -NoNewline -ForegroundColor 'red' -Object 'Not Connected'
        }
        Write-Host -Object "]"
    }
    PROCESS
    {
        # Test if OVA already downloaded
        If(Test-Path $Destination)
        {
            # If Already exists then
            # Compute MD5 Hash of the current file to determine if udpate is required
            $Md5 = New-Object -TypeName System.Security.Cryptography.MD5CryptoServiceProvider

            $Hash = [System.BitConverter]::ToString($Md5.ComputeHash([System.IO.File]::ReadAllBytes($Destination))) -Replace "-",""

            $Compare = Invoke-WebRequest -Method 'GET' -URI $Digests

            Write-Host -NoNewline -Object "CoreOS OVA `"$UpdateChannel`" status ["
            
            If($Compare.RawContent -Match $Hash)
            {
                Write-Host -NoNewLine -ForegroundColor 'green' -Object "Up-To-Date"
                Write-Host -Object "]"
            }
            Else
            {
                Write-Host -NoNewLine -ForegroundColor 'yellow' -Object "Updating"
                Write-Host -Object "]"

                Remove-Item -Force -Path $Destination

                
                Start-BitsTransfer -Source $URI -Destination $Destination
            }        
        }
        Else
        {
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



Function Import-CoreOS
{
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
    BEGIN
    {
        Import-Module -Name 'VMware.VimAutomation.Core'

        If(-Not $(Test-Path -Path $OVAPath))
        {
            Update-CoreOS
        }
    }
    PROCESS
    {
        # Import OVA in VMHost
        If($VMHost)
        {
            $VMHostObject = Get-VMHost -Name $VMHost
            
        }
        Elseif($Cluster)
        {
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
        If($(Get-VMHost).Length -gt 1)
        {
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

Function Write-CoreOSCloudConfig
{
    PARAM(
        [parameter(mandatory=$false,ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)]
        [VMware.VimAutomation.ViCore.Types.V1.Inventory.VirtualMachine]
        $VM,

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
    BEGIN
    {
        # Get virtual machine object
        # https://blogs.vmware.com/PowerCLI/2016/04/powercli-best-practice-correct-use-strong-typing.html
        If($VM -is [VMware.VimAutomation.ViCore.Types.V1.Inventory.VirtualMachine])
        {
            $Name = $VM.Name
        }
        Else
        {
            If($VMHost -and $Cluster){Throw "Processing VMhost and Cluster is not supported"}
            ElseIf($VMHost){$VM = Get-VMHost -Name "${VMHost}" | Get-VM -Name "${Name}"}
            ElseIf($Cluster){$VM = Get-Cluster -Name "${Cluster}" | Get-VM -Name "${Name}"}
            Else{Throw "Missing vSphere hosting agurment:`"-VMHost`" or `"-Cluster`""}
        }

        # Temporary VMX file to inject cloud-config data
        $vmxTemp = "$($([System.IO.FileInfo]$CloudConfigPath).DirectoryName)\$($Name).vmx"

        # Convert cloud-config data to Base-64 for VMX injection
        $cc = Get-Content -Path "${CloudConfigPath}" -Raw
        $b = [System.Text.Encoding]::UTF8.GetBytes($cc)
        $EncodedText = [System.Convert]::ToBase64String($b)
    }
    PROCESS
    {

        # Power-Off the virtualmachine if powered-on.
        If ($VM.PowerState -eq "PoweredOn"){ $VM | Stop-VM -Confirm:$False }

        # VMX file download from vSphere infrastructure
        $Datastore = $VM | Get-Datastore
        $vmxRemote = "$($Datastore.name):\$($Name)\$($Name).vmx"

        If (Get-PSDrive | Where-Object { $_.Name -eq $Datastore.Name})
        {
            Remove-PSDrive -Name $Datastore.Name
        }
        
        New-PSDrive -Location $Datastore -Name $Datastore.Name -PSProvider VimDatastore -Root "\" > $Null
        Copy-DatastoreItem -Item $vmxRemote -Destination $vmxTemp > $Null

        # Cleanup existing guestinfo.coreos.config.* data
        $vmx = $($(Get-Content $vmxTemp | Select-String -Pattern 'guestinfo.coreos.config.data' -NotMatch) -join "`n").Trim()
        $vmx = $(($vmx | Select-String -Pattern 'guestinfo.coreos.config.data.encoding' -NotMatch) -join "`n").Trim()
        $vmx += "`n"

        # Inject new cloud-config data
        $vmx += "guestinfo.coreos.config.data = $EncodedText" + "`n"
        $vmx += "guestinfo.coreos.config.data.encoding = base64" + "`n"
    
        $GuestInfo.Keys | foreach{
            $vmx += "$($_) = $($GuestInfo[$_])" + "`n"

        }

        # Save new configuration in temporary VMX file
        $vmx | Out-File $vmxTemp -Encoding 'ASCII'

        # Replace vSphere Infrastructure VMX file with temporary one
        Copy-DatastoreItem -Force -Item $vmxTemp -Destination $vmxRemote

        # Power-On virtaul machine and watch for VMware Tools status
        $VM | Start-VM > $Null
        
        Wait-VMGuest -VM $VMObject -Sleep 10
    }
    END
    {
        Remove-PSDrive -Name $Datastore.Name > $Null
    }
}


Function New-K8sIpAddress
{
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
PS C:\> New-k8sIpAddress -Subnet '10.0.0.0' -StartFrom 50 -Count 3

10.0.0.53

This command returns an ip address in the 10.0.0.0 subent with a last octet sets to "50 + 3"
#>
    PARAM(
        [parameter(mandatory=$true)]
        [String]
        $Subnet,

        [parameter(mandatory=$true)]
        [String]
        $StartFrom = 50,

        [parameter(mandatory=$false)]
        [Int]
        $Count = 1
    )
    PROCESS
    {
        # Parse Subnet address to extract the first 3 octets
        $Subnet -Match '^(?<BeginIP>\d{1,3}\.\d{1,3}\.\d{1,3})\.\d{1,3}$' > $Null

        Write-Output -InputObject "$($Matches.BeginIP).$($Count + $StartFrom)"
    }
}


Function Get-K8sEtcdIP
{
    PARAM(
        [parameter(mandatory=$false)]
        [string]
        $Subnet,
        
        [parameter(mandatory=$false)]
        [int]
        $StartFrom = 50,

        [parameter(mandatory=$false)]
        [int]
        $Count = 1
    )
    BEGIN
    {
        $IpArray = @()
    }
    PROCESS
    {
        For($i = 1 ; $i -le $Count; $i++){
            $IpArray += New-K8sIpAddress -Subnet $Subnet -StartFrom $StartFrom -Count $i
        }
    }
    END
    {
        Write-Host -NoNewline -Object "Etcd IP Adresses ["
        Write-Host -NoNewline -ForegroundColor 'green' -Object "${IpArray}"
        Write-Host -Object "]"

        # Return the array containing the etcd ip address list
        Write-Output -InputObject $IpArray
    }
}

Function Get-K8sEtcdInitialCluster
{
    PARAM(
        [parameter(mandatory=$false)]
        [string]
        $NamePrefix = 'etcd',

        [parameter(mandatory=$false)]
        [string[]]
        $IpAddress
    )
    BEGIN
    {
        $ClusterArray = @()
    }
    PROCESS
    {
        For($cm = 0 ; $cm -le $IpAddress.Length -1 ; $cm++)
        {
            $ClusterArray += "${NamePrefix}$("{0:D3}" -f $($cm +1))=http://$($IpAddress[$cm]):2380"
        }
    }
    END
    {
        # Flatten the array with comma separators
        $ClusterArray = $ClusterArray -Join ','
        
        Write-Host -NoNewline -Object "Initial etcd cluster ["
        Write-Host -NoNewline -ForegroundColor 'green' -Object "${ClusterArray}"
        Write-Host -Object "]"

        # Return the array containing the etcd ip address list
        Write-Output -InputObject $ClusterArray
    }
}

Function Get-K8sEtcdEndpoint
{
    PARAM(
        [parameter(mandatory=$false)]
        [string[]]
        $IpAddress,

        [parameter(mandatory=$false)]
        [string]
        $Protocol = 'http',

        [parameter(mandatory=$false)]
        [int]
        $port = 2379
    )
    BEGIN
    {
        $ClusterArray = @()
    }
    PROCESS
    {
        Foreach($Item in $IpAddress){
            $ClusterArray += "${Protocol}://${Item}:${Port}"
        }
    }
    END
    {
        # Flatten the array with comma separators
        $ClusterArray = $ClusterArray -Join ','

        Write-Host -NoNewline -Object "Etcd endpoints ["
        Write-Host -NoNewline -ForegroundColor 'green' -Object "${ClusterArray}"
        Write-Host -Object "]"

        # Return the array containing the etcd ip address list
        Write-Output -InputObject $ClusterArray
    }
}

Function Get-K8sControllerIP
{
    PARAM(
        [parameter(mandatory=$false)]
        [string]
        $Subnet,
        
        [parameter(mandatory=$false)]
        [int]
        $StartFrom = 100,

        [parameter(mandatory=$false)]
        [int]
        $Count = 1,
        
        [parameter(mandatory=$false)]
        [string]
        $ControllerCluster = '10.3.0.1'
    )
    BEGIN
    {
        $IpArray = @()
    }
    PROCESS
    {
        For($i = 1 ; $i -le $Count; $i++)
        {
            $IpArray += New-K8sIpAddress -Subnet $Subnet -StartFrom $StartFrom -Count $i
        }
    }
    END
    {
        $IpArray += $ControllerCluster
        
        Write-Host -NoNewline -Object "Controller IP Adresses ["
        Write-Host -NoNewline -ForegroundColor 'green' -Object "${IpArray}"
        Write-Host -Object "]"

        # Return the array containing the controller ip address list
        Write-Output -InputObject $IpArray
    }
}

Function Get-K8sWorkerIP
{
    PARAM(
        [parameter(mandatory=$false)]
        [string]
        $Subnet,
        
        [parameter(mandatory=$false)]
        [int]
        $StartFrom = 50,

        [parameter(mandatory=$false)]
        [int]
        $Count = 1
    )
    BEGIN
    {
        $IpArray = @()
    }
    PROCESS
    {
        For($i = 1 ; $i -le $Count; $i++){
            $IpArray += New-K8sIpAddress -Subnet $Subnet -StartFrom $StartFrom -Count $i
        }
    }
    END
    {
        Write-Host -NoNewline -Object "Worker IP Adresses ["
        Write-Host -NoNewline -ForegroundColor 'green' -Object "${IpArray}"
        Write-Host -Object "]"

        # Return the array containing the etcd ip address list
        Write-Output -InputObject $IpArray
    }
}

Function New-K8sEtcdCluster
{
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
        $StartFrom = 50,

        [parameter(mandatory=$false)]
        [int]
        $Count = 1,

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
        [int]
        $numCpu = 1,

        [parameter(mandatory=$false)]
        [int]
        $MemoryMB = 512,

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
    BEGIN
    {
        Write-Host -NoNewline -Object "Deploying etcd count ["
        Write-Host -NoNewline -ForegroundColor 'green' -Object "${Count}"
        Write-Host -Object "]"

        $IpAddresses = Get-K8sEtcdIP -Subnet $Subnet -StartFrom $StartFrom -Count $Count

        $EtcdCluster = Get-K8sEtcdInitialCluster -NamePrefix $NamePrefix -IpAddress $IpAddresses
    }
    PROCESS
    {
        For($e = 0; $e -lt $Count ; $e++)
        {
            $Name = "${NamePrefix}$("{0:D3}" -f $($e +1))"
            $IP = New-K8sIpAddress -Subnet $Subnet -StartFrom $StartFrom -Count $($e +1)

            Write-Host -NoNewline -Object "Deploying etcd host ["
            Write-Host -NoNewline -ForegroundColor 'cyan' -Object ($e +1)
            Write-Host -Object "]"
            
            $ConfigPath = "${pwd}\.vsphere\machines\$Name\openstack\latest\user-data"

            New-Item -Force -ItemType 'Directory' -Path $(([System.IO.fileInfo]$ConfigPath).DirectoryName) > $Null

            $Config = Get-Content -Path "${CloudConfigFile}" 
            $Config = $Config -Replace '\{\{ETCD_NODE_NAME\}\}',$Name
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
            For( $d = 0; $d -le $DNS.Length -1 ; $d++)
            {
                $GuestInfo += @{"guestinfo.dns.server.$($d)" = $DNS[$d]}
            }

            # Provision VM
            If($VMHost -and $Cluster)
            {
                Throw "Processing VMhost and Cluster is not supported"
            }
            ElseIf($VMHost)
            {
                Import-CoreOS -Name "${Name}" -DataStore "${DataStore}" -VMHost "${VMHost}" -PortGroup "${PortGroup}" -DiskStorageFormat "${DiskstorageFormat}"

                $VMObject = Get-VMHost -Name "${VMHost}"   | Get-VM -Name "${Name}"
            }
            ElseIf($Cluster)
            {
                Import-CoreOS -Name "${Name}" -DataStore "${DataStore}" -Cluster "${Cluster}" -PortGroup "${PortGroup}" -DiskStorageFormat "${DiskstorageFormat}"

                $VMObject = Get-Cluster -Name "${Cluster}"   | Get-VM -Name "${Name}"
            }
            Else
            {
                Throw "Missing vSphere hosting agurment:`"-VMHost`" or `"-Cluster`""
            }

            # Configure and Start VM
            Set-CoreOSVirtualHardware -VM $VMObject -numCpu $numCpu -MemoryMB $MemoryMB
            Write-CoreOSCloudConfig -VM $VMObject -GuestInfo $GuestInfo -CloudConfigPath "${ConfigPath}"
        }
    }

}


Function New-K8sControllerCluster
{
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
        $StartFrom = 100,

        [parameter(mandatory=$false)]
        [int]
        $Count = 1,

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
        [int]
        $numCpu = 1,

        [parameter(mandatory=$false)]
        [int]
        $MemoryMB = 1024,

        [parameter(mandatory=$false)]
        [string[]]
        $HardDisk = @(4GB, 5GB, 6GB),

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
        $CloudConfigFile = "${pwd}\controller-cloud-config.yaml",
        
        [parameter(mandatory=$false)]
        [PSCredential]
        $SSHCredential,

        [parameter(mandatory=$false)]
        [string]
        $InstallScript,

        [parameter(mandatory=$false)]
        [string]
        $EtcdEndpoints,

        [parameter(mandatory=$false)]
        [string]
        $ControllerCluster,

        [parameter(mandatory=$false)]
        [string]
        $ControllerEndpoint
    )
    BEGIN
    {
        $IpAddresses = Get-K8sControllerIP -Subnet $Subnet -StartFrom $StartFrom -Count $Count -ControllerCluster $ControllerCluster
        
        Write-Host -NoNewline -Object "Deploying controller count ["
        Write-Host -NoNewline -ForegroundColor 'green' -Object "${Count}"
        Write-Host -Object "]"
    }
    PROCESS
    {
        For($c = 0; $c -lt $Count ; $c++)
        {
            $Name = "${NamePrefix}$("{0:D3}" -f $($c +1))"
            $IP = New-K8sIpAddress -Subnet $Subnet -StartFrom $StartFrom -Count $($c +1)

            Write-Host -NoNewline -Object "Deploying controller host ["
            Write-Host -NoNewline -ForegroundColor 'cyan' -Object ($c +1)
            Write-Host -Object "]"

            # Cloud Config
            $ConfigPath = "${pwd}\.vsphere\machines\$Name\openstack\latest\user-data"
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
            For( $d = 0; $d -le $DNS.Length -1 ; $d++)
            {
                $GuestInfo += @{"guestinfo.dns.server.$($d)" = $DNS[$d]}
            }

            # Provision VM
            If($VMHost -and $Cluster)
            {
                Throw "Processing VMhost and Cluster is not supported"
            }
            ElseIf($VMHost)
            {
                Import-CoreOS -Name "${Name}" -DataStore "${DataStore}" -VMHost "${VMHost}" -PortGroup "${PortGroup}" -DiskStorageFormat "${DiskstorageFormat}"

                $VMObject = Get-VMHost -Name "${VMHost}"   | Get-VM -Name "${Name}"
            }
            ElseIf($Cluster)
            {
                Import-CoreOS -Name "${Name}" -DataStore "${DataStore}" -Cluster "${Cluster}" -PortGroup "${PortGroup}" -DiskStorageFormat "${DiskstorageFormat}"

                $VMObject = Get-Cluster -Name "${Cluster}"   | Get-VM -Name "${Name}"
            }
            Else
            {
                Throw "Missing vSphere hosting agurment:`"-VMHost`" or `"-Cluster`""
            }

            # Configure and Start VM
            Set-CoreOSVirtualHardware -VM $VMObject -numCpu $numCpu -MemoryMB $MemoryMB -HardDisk $HardDisk
            Write-CoreOSCloudConfig -VM $VMObject -GuestInfo $GuestInfo -CloudConfigPath "${ConfigPath}"

            Test-TcpConnection -ComputerName $IP -Port 22 -Loop

            # Open SSH Session
            $SSHSessionID = $(New-SSHSession -ComputerName $IP -Credential $SSHCredential -Force).SessionID

            # Generate and copy SSL asset
            Send-SSHMachineSSL -CertificateBaseName 'apiserver' -CommonName "kube-apiserver-${IP}" -IpAddresses $IpAddresses `
            -SubjectAlternativeName $ControllerEndpoint -Computername $IP -Credential $SSHCredential  -SSHSession $SSHSessionID
                    
            # Copy kubernetes worker configuration asset
            Set-ScpFile -Force -LocalFile "${InstallScript}" -RemotePath '/tmp/' -ComputerName $IP -Credential $SSHCredential
            Invoke-SSHCommand -Index $SSHSessionID -Command 'cd /tmp/ && mv controller-install.sh vsphere-user-data'
            Invoke-SSHCommand -Index $SSHSessionID -Command 'sudo mkdir -p /var/lib/coreos-vsphere && sudo mv /tmp/vsphere-user-data /var/lib/coreos-vsphere/'
            #Invoke-SSHCommand -Index $SSHSessionID -Command 'sudo systemctl enable docker'

            # Close SSH Session
            # Remove-SSHSession -SessionId $SSHSessionID
            
            # Restart Virtual Machine
            Restart-VMGuest -VM $VMObject > $null

            Wait-VMGuest -VM $VMObject -Sleep 10 -Reboot
        }
    }
}


Function New-K8sWorkerCluster
{
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
        $StartFrom = 200,

        [parameter(mandatory=$false)]
        [int]
        $Count = 1,

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
        [int]
        $numCpu = 1,

        [parameter(mandatory=$false)]
        [int]
        $MemoryMB = 1024,

        [parameter(mandatory=$false)]
        [string[]]
        $HardDisk = @(4GB, 5GB, 6GB),

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

        [parameter(mandatory=$true)]
        [string]
        $EtcdEndpoints,

        [parameter(mandatory=$true)]
        [string]
        $ControllerEndpoint
    )
    BEGIN
    {
        Write-Host -NoNewline -Object "Deploying worker count ["
        Write-Host -NoNewline -ForegroundColor 'green' -Object "${Count}"
        Write-Host -Object "]"
    }
    PROCESS
    {
        For($w = 0; $w -lt $Count ; $w++)
        {
            $Name = "${NamePrefix}$("{0:D3}" -f $($w +1))"
            $IP = New-K8sIpAddress -Subnet $Subnet -StartFrom $StartFrom -Count $($w +1)

            Write-Host -NoNewline -Object "Deploying worker host ["
            Write-Host -NoNewline -ForegroundColor 'cyan' -Object ($w +1)
            Write-Host -Object "]"

            # Cloud Config
            $ConfigPath = "${pwd}\.vsphere\machines\$Name\openstack\latest\user-data"
            New-Item -Force -ItemType 'Directory' -Path $(([System.IO.fileInfo]$ConfigPath).DirectoryName) > $Null
            $Config = Get-Content -Path "${CloudConfigFile}"
            $Config = $Config -Replace '\{\{ETCD_ENDPOINTS\}\}',$EtcdEndpoints
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
            For( $d = 0; $d -le $DNS.Length -1 ; $d++)
            {
                $GuestInfo += @{"guestinfo.dns.server.$($d)" = $DNS[$d]}
            }

            # Provision VM
            If($VMHost -and $Cluster)
            {
                Throw "Processing VMhost and Cluster is not supported"
            }
            ElseIf($VMHost)
            {
                Import-CoreOS -Name "${Name}" -DataStore "${DataStore}" -VMHost "${VMHost}" -PortGroup "${PortGroup}" -DiskStorageFormat "${DiskstorageFormat}"

                $VMObject = Get-VMHost -Name "${VMHost}"   | Get-VM -Name "${Name}"
            }
            ElseIf($Cluster)
            {
                Import-CoreOS -Name "${Name}" -DataStore "${DataStore}" -Cluster "${Cluster}" -PortGroup "${PortGroup}" -DiskStorageFormat "${DiskstorageFormat}"

                $VMObject = Get-Cluster -Name "${Cluster}"   | Get-VM -Name "${Name}"
            }
            Else
            {
                Throw "Missing vSphere hosting agurment:`"-VMHost`" or `"-Cluster`""
            }

            # Configure and Start VM
            Set-CoreOSVirtualHardware -VM $VMObject -numCpu $numCpu -MemoryMB $MemoryMB -HardDisk $HardDisk
            Write-CoreOSCloudConfig -VM $VMObject -GuestInfo $GuestInfo -CloudConfigPath "${ConfigPath}"

            Test-TcpConnection -ComputerName $IP -Port 22 -Loop

            # Open SSH Session
            $SSHSessionID = $(New-SSHSession -ComputerName $IP -Credential $SSHCredential -Force).SessionID

            Send-SSHMachineSSL -CertificateBaseName 'worker' -CommonName "kube-worker-${IP}" -IpAddresses $IP `
            -Computername $IP -Credential $SSHCredential -SSHSession $SSHSessionID

            # Copy kubernetes worker configuration asset
            Set-ScpFile -Force -LocalFile "${InstallScript}" -RemotePath '/tmp/' -ComputerName $IP -Credential $SSHCredential
            Invoke-SSHCommand -Index $SSHSessionID -Command 'cd /tmp/ && mv worker-install.sh vsphere-user-data'
            Invoke-SSHCommand -Index $SSHSessionID -Command 'sudo mkdir -p /var/lib/coreos-vsphere && sudo mv /tmp/vsphere-user-data /var/lib/coreos-vsphere/'
            # Invoke-SSHCommand -Index $SSHSessionID -Command 'sudo systemctl enable docker'

            # Close SSH Session
            # Remove-SSHSession -SessionId $SSHSessionID
            
            # Restart Virtual Machine
            Restart-VMGuest -VM $VMObject > $null

            Wait-VMGuest -VM $VMObject -Sleep 10 -Reboot
        }
    }
}


Function Test-TcpConnection
{
    PARAM(
        [parameter(mandatory=$true)]
        [string[]]
        $ComputerName,

        [parameter(mandatory=$true)]
        [string[]]
        $Port,

        [parameter(mandatory=$False)]
        [string]
        $Timeout = 3000,

        [parameter(mandatory=$False)]
        [switch]
        $Loop
    )
    BEGIN
    {
        Function Start-Connect
        {
            $Socket = New-Object -TypeName 'System.Net.Sockets.TcpClient'
            $IAsyncResult = [IAsyncResult] $Socket.BeginConnect($Computer, $Target, $null, $null)
            $Wait = Measure-Command { $Result = $iasyncresult.AsyncWaitHandle.WaitOne($Timeout, $true) } | % totalseconds
            New-Object -TypeName 'PsObject' -Property @{
                'From' = $env:ComputerName ;
                'To' = $Computer ;
                'Port' = $Target ;
                'Timeout' = $Timeout ;
                'Connected' = $Socket.Connected ;
                'Timing' = $Wait ;
            }
        }
    }
    PROCESS
    {
        ForEach($Computer in $ComputerName){
            ForEach($Target in $Port){
                If($Loop)
                {
                    $Connected = $False
                    While($Connected -eq $False)
                    {
                        Start-Sleep -Seconds 1
                        $CommandResult = Start-Connect
                        Write-Host -NoNewline -Object "$($CommandResult.To): listening on tcp port:`"$($CommandResult.Port)`" ["
                        If($(Start-Connect).Connected){
                            Write-Host -NoNewline -ForegroundColor 'green' -Object "$($CommandResult.Connected)"
                            Write-Host -Object "]"
                            
                            $Connected = $True
                            
                            Write-Output -InputObject $CommandResult
                        }
                        Else
                        {
                            Write-Host -NoNewline -ForegroundColor 'red' -Object "$($CommandResult.Connected)"
                            Write-Host -Object "]"
                        }
                    }
                }
                Else
                {
                    Start-Connect
                }
            }
        }
    }
}

Function Set-CoreOSVirtualHardware{
    PARAM(
        [parameter(mandatory=$false,ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)]
        [VMware.VimAutomation.ViCore.Types.V1.Inventory.VirtualMachine]
        $VM,

        [parameter(mandatory=$false)]
        [string]
        $VMHost,

        [parameter(mandatory=$false)]
        [string]
        $Cluster,

        [parameter(mandatory=$false)]
        [string]
        $Name,

        [parameter(mandatory=$false)]
        [int]
        $numCpu,

        [parameter(mandatory=$false)]
        [int]
        $MemoryMB,

        [parameter(mandatory=$false)]
        [string[]]
        $HardDisk
    )
    BEGIN
    {   
        # https://blogs.vmware.com/PowerCLI/2016/04/powercli-best-practice-correct-use-strong-typing.html
        If(-not $VM)
        {
            If($VMHost -and $Cluster){Throw "Processing VMhost and Cluster is not supported"}
            ElseIf($VMHost){$VM = Get-VMHost -Name "${VMHost}" | Get-VM -Name "${Name}"}
            ElseIf($Cluster){$VM = Get-Cluster -Name "${Cluster}" | Get-VM -Name "${Name}"}
            Else{Throw "Missing vSphere hosting agurment:`"-VMHost`" or `"-Cluster`""}
        }
        Write-Host -NoNewline -Object "$($VM.Name): Setting up virtual hardware ["
    }
    PROCESS
    {
        $VM | Set-VM -numCpu "${numCpu}" -MemoryMB "${MemoryMB}" -Confirm:$false > $Null

        If($HardDisk)
        {
            Foreach($Disk in $HardDisk)
            {
                $VM | New-HardDisk -CapacityKB $($Disk /1KB) -Disktype 'flat' -ThinProvisioned > $Null
            }
        }
        Write-Host -ForegroundColor 'green' -NoNewline -Object "CPU:${numCpu}, Memory:${MemoryMB}, HardDisk:${HardDisk}"
        Write-Host -Object "]"
    }
}

Function Test-K8sInstall
{
    PARAM(
        [paramerter(mandatory=$true)]
        [string[]]
        $EtcdComputerName,

        [paramerter(mandatory=$true)]
        [string[]]
        $ControllerComputerName,

        [paramerter(mandatory=$true)]
        [string[]]
        $WorkerComputerName
    )
    BEGIN
    {
        $ErrorActionPreference = 'Stop'
    }
    PROCESS
    {
        # Etcd
        For($etcd = 0; $etcd -le $EtcdComputerName.Lenght -1 ; $etcd++){
            Test-TcpConnection -Computername $ComputerName[$etcd] -Port 2379,2380
        }

        # Controller
        # Ommits the last record as it contain the cluster IP
        For($ctrl = 0; $ctrl -lt $ControllerComputerName.Lenght -1 ; $ctrl++){
            Test-TcpConnection -Computername $ComputerName[$ctrl] -Port 8080,443
        }

        # Worker
        For($work = 0; $work -le $ControllerComputerName.Lenght -1 ; $work++){
            Test-TcpConnection -Computername $ComputerName[$work] -Port 8080,443
        }
    }
}

Function Wait-VMGuest{
    PARAM(
        [parameter(mandatory=$false,ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)]
        [VMware.VimAutomation.ViCore.Types.V1.Inventory.VirtualMachine]
        $VM,

        [parameter(mandatory=$false)]
        [string]
        $VMHost,

        [parameter(mandatory=$false)]
        [string]
        $Cluster,

        [parameter(mandatory=$false)]
        [string]
        $Name,

        [parameter(mandatory=$false)]
        [int]
        $Sleep = 1,

        [parameter(mandatory=$false)]
        [switch]
        $Reboot          
    )
    BEGIN
    {
        $Status = 'toolsNotRunning'
        $Operation = 'Boot'

        If($Reboot){ $Operation = 'Reboot'}
        If(-not $VM -is [VMware.VimAutomation.ViCore.Types.V1.Inventory.VirtualMachine])
        {
            If($VMHost -and $Cluster){Throw "Processing VMhost and Cluster is not supported"}
            ElseIf($VMHost){$VM = Get-VMHost -Name "${VMHost}" | Get-VM -Name "${Name}"}
            ElseIf($Cluster){$VM = Get-Cluster -Name "${Cluster}" | Get-VM -Name "${Name}"}
            Else{Throw "Missing vSphere hosting agurment:`"-VMHost`" or `"-Cluster`""}
        }
    }
    PROCESS{
        while ($Status -eq 'toolsNotRunning')
        {
            $Status = ($VM | Get-View).Guest.ToolsStatus

            Start-Sleep -Seconds $Sleep
                
            Write-Host -NoNewline -Object "$($VM.Name) `(${Operation}`): VMware Tools Status [" 
            Write-Host -NoNewline -ForegroundColor 'yellow' -Object $Status
            Write-Host -Object "]"
        }
        Write-Host -NoNewline -Object "$($VM.Name) `(${Operation}`): VMware Tools Status [" 
        Write-Host -NoNewline -ForegroundColor 'green' -Object $Status
        Write-Host -Object "]"
    }
}