PARAM(
    [parameter(mandatory=$false)][String]$VMHost,
    [parameter(mandatory=$false)][String]$Cluster ='Cluster-Prod',
    [parameter(mandatory=$false)][String]$PortGroup = 'fre-server',
    [parameter(mandatory=$false)][String]$Datastore = 'FAS01_PROD_SATA_04',
    [parameter(mandatory=$false)][String]$DiskStorageFormat = 'thin',

    [parameter(mandatory=$false)][String]$UpdateChannel = 'beta',

    # Etcd configuration
    [parameter(mandatory=$false)][Int]$EtcdCount = 3,
    [parameter(mandatory=$false)][Int]$EtcdVMMemory = 512,
    [parameter(mandatory=$false)][String]$EtcdSubnet = '192.168.251.0',
    [parameter(mandatory=$false)][Int]$EtcdCIDR = 24,
    [parameter(mandatory=$false)][String]$EtcdGateway = '192.168.251.254',

    # Kubernetes Controller configuration
    [parameter(mandatory=$false)][Int]$ControllerCount = 1,
    [parameter(mandatory=$false)][Int]$ControllerVMMemory = 2048,
    [parameter(mandatory=$false)][String]$ControllerSubnet = '192.168.251.0',
    [parameter(mandatory=$false)][Int]$ControllerCIDR = 24,
    [parameter(mandatory=$false)][String]$ControllerGateway = '192.168.251.254',

    # Kubernetes Worker configuration
    [parameter(mandatory=$false)][Int]$WorkerCount = 1,
    [parameter(mandatory=$false)][Int]$WorkerVMMemory = 2048,
    [parameter(mandatory=$false)][Int]$WorkerVMCpu = 1,
    [parameter(mandatory=$false)][String]$WorkerSubnet = '192.168.251.0',
    [parameter(mandatory=$false)][Int]$WorkerCIDR = 24,
    [parameter(mandatory=$false)][String]$WorkerGateway = '192.168.251.254',

    # Disk configuration
    [parameter(mandatory=$false)][Int]$NodeDisks = 3,
    [parameter(mandatory=$false)][Int]$DiskSize = 5,

    # Common Network Properties
    [parameter(mandatory=$false)][hashtable]$CommonGuestInfo = @{
        'guestinfo.dns.server.0' = '192.168.1.1';
        'guestinfo.dns.server.1' = '192.168.1.2';
    }
)
BEGIN{
    $ErrorActionPreference = 'stop'
    # Import Powercli 6.3 Module
    Import-Module -Force -Name 'VMware.VimAutomation.Core'
    Import-Module -Force -Name "${pwd}\Modules\MyPowershellToolkit.Powercli.vSphere.psm1"

    # Load Machine configuration from config
    $Config = ([System.IO.FileInfo]"${pwd}\config.rb").FullName
    If (Test-Path $Config)
    {
        Get-Content $Config | Invoke Expression
    }

    If ($WorkerVMMemory -le 1024)
    {
        Write-Warning -Message 'Workers should have at least 1024 MB of Memory'
    }

    $ControllerClusterIP = "10.3.0.1"

    $EtcdCloudConfigPath = ([System.IO.FileInfo]"${pwd}\etcd-cloud-config.yaml").FullName

    $ControllerCloudConfigPath = ([System.IO.FileInfo]"${pwd}\..\generic\controller-install.sh").FullName
    $WorkerCloudConfigPath = ([System.IO.FileInfo]"${pwd}\..\generic\worker-install.sh").FullName

    Function Get-EtcdIP([string]$Subnet,[int]$Number){
        $Subnet -Match '^(?<BeginIP>\d{1,3}\.\d{1,3}\.\d{1,3})\.\d{1,3}$' > $Null

        Write-Output -InputObject "$($Matches.BeginIP).$($Number + 50)"
    }

    Function Get-ControllerIP([string]$Subnet,[int]$Number){
        $Subnet -Match '^(?<BeginIP>\d{1,3}\.\d{1,3}\.\d{1,3})\.\d{1,3}$' > $Null

        Write-Output -InputObject "$($Matches.BeginIP).$($Number + 100)"
    }

    Function Get-WorkerIP([string]$Subnet,[int]$Number){
        $Subnet -Match '^(?<BeginIP>\d{1,3}\.\d{1,3}\.\d{1,3})\.\d{1,3}$' > $Null

        Write-Output -InputObject "$($Matches.BeginIP).$($Number + 200)"
    }

    # Building array of Controller IP addresses as per given controller count
    # Adding Controller Cluster IP address at the end of the list
    $ControllerIPs = @()
    For($i =1 ; $i -le $ControllerCount; $i++){$ControllerIPs += Get-ControllerIP -Subnet $ControllerSubnet -Number $i}
    $ControllerIPs += $ControllerClusterIP
    Write-Verbose -Message "Controller IPs:`"$ControllerIPs`""

    # Building array of Etcd IP addresses as per given etcd count
    $EtcdIPs = @()
    For($i = 1 ; $i -le $EtcdCount; $i++){$EtcdIPs += Get-EtcdIP -Subnet $EtcdSubnet -Number $i}
    

    # Building a single string for Etcd Cluster Node list containing Etcd hostnames and URLs as per given etcd count
    $InitialEtcdCluster = @()
    For($i = 0 ; $i -lt $EtcdIPs.Length; $i++){$InitialEtcdCluster += "k8setcd$("{0:D3}" -f $($i +1))=http://$($EtcdIPs[$i]):2380"}
    $InitialEtcdCluster = $InitialEtcdCluster -Join ','
    Write-Verbose "Initial Etcd Cluster:`"$InitialEtcdCluster`""

    # Building a single string for Etcd Endpoints Node list containing Etcd URLs as per given etcd count
    $EtcdEndpoints = @()
    Foreach($IPAddress in $EtcdIPs){$EtcdEndpoints += "http://${IPAddress}:2379"}
    $EtcdEndpoints = $EtcdEndpoints -Join ','
    Write-Verbose -Message "Etcd Endpoints:`"$EtcdEndpoints`""

    Function Write-MachineSSL([string]$Machine, [string]$CertificateBaseName, [String]$CommonName, [String[]]$IpAddresses){
        $ZipFile = "${pwd}/${CommonName}"
        $IPString = @()
        For($i = 0 ; $i -lt $IpAddresses.Length; $i++){$IPString += "IP.$($i +1) = $($IpAddresses[$i])"}
        
        .\Lib\Write-SSL.ps1 -OutputPath "${pwd}\ssl" -Name "${CertificateBaseName}" -CommonName "${CommonName}" -SubjectAlternativeName $IpString
    }
}  
PROCESS{
    
    # Root CA
    ##################################################
    Write-Verbose -Message "Generating Root CA"
    New-Item -Force -Type 'Directory' -Path "${pwd}\ssl" > $Null
    .\Lib\Write-SSLCA.ps1 -OutputPath "${pwd}\ssl"

    # Admin certificate
    ##################################################
    Write-Verbose -Message "Admin certficicate"
    .\Lib\Write-SSL.ps1 -OutputPath "${pwd}\ssl" -Name 'admin' -CommonName 'kube-admin'

    # OVA Download
    ##################################################
    $OVAPath = "${pwd}\.ova\coreos_production_vmware_ova.ova"
    Update-CoreOs -UpdateChannel $UpdateChannel -Destination $OVAPath

    # Etcd
    ##################################################
    Write-Verbose -Message "Provisionning ETCd hosts"
    For($i = 0; $i -lt $EtcdCount; $i++){
        $EtcdName = "k8setcd$("{0:D3}" -f $($i +1))"
        $EtcdIP = Get-EtcdIP -Subnet $EtcdSubnet -Number $($i +1)
        
        $EtcdConfigPath = "${pwd}\conf\etcd\$EtcdName\openstack\latest\user-data"

        New-Item -Force -ItemType 'Directory' -Path $(([System.IO.fileInfo]$EtcdConfigPath).DirectoryName) > $Null

        $EtcdConfig = $(Get-Content -Path "${pwd}\etcd-cloud-config.yaml") -Replace '\{\{ETCD_NODE_NAME\}\}',$EtcdName
        $EtcdConfig = $EtcdConfig -Replace '\{\{ETCD_INITIAL_CLUSTER\}\}',$InitialEtcdCluster
        Set-Content -Path $EtcdConfigPath -Value $EtcdConfig

        $GuestInfo = @{
            'guestinfo.hostname' = "${EtcdName}";
            'guestinfo.interface.0.name' = 'ens192';
            'guestinfo.interface.0.dhcp' = 'no';
            'guestinfo.interface.0.role' = 'private';
            'guestinfo.interface.0.ip.0.address' = "${EtcdIP}/${EtcdCIDR}";
            'guestinfo.interface.0.route.0.gateway' = "${EtcdGateway}";
            'guestinfo.interface.0.route.0.destination' = '0.0.0.0/0'
        }
        $GuestInfo += $CommonGuestInfo

        Import-CoreOS -Name "${EtcdName}" -DataStore "${DataStore}" -Cluster "${Cluster}" -PortGroup "${PortGroup}" -DiskStorageFormat "${DiskstorageFormat}"
        Write-CoreOSCloudConfig -Name "${EtcdName}" -GuestInfo $GuestInfo -CloudConfigPath "${EtcdConfigPath}" -Cluster "${Cluster}"   
    }


    # Controller
    ##################################################
    Write-Verbose -Message "Controller certificates"
    For($i = 0; $i -lt $ControllerCount; $i++){
        $ControllerName = "k8sctrl$("{0:D3}" -f $($i +1))"
        $ControllerIP = Get-ControllerIP -Subnet $ControllerSubnet -Number $($i +1)

        Write-MachineSSL -Machine $ControllerName -CertificateBaseName 'apiserver' -CommonName "kube-apiserver-${ControllerIP}" -IpAddresses $ControllerIPs
    }

    # Worker
    ##################################################
    Write-Verbose -Message "Worker certificates"
    For($i = 0; $i -lt $WorkerCount; $i++){
        $WorkerName = "k8swork$("{0:D3}" -f $($i +1))"
        $WorkerIP = Get-WorkerIP -Subnet $WorkerSubnet -Number $($i +1)

        Write-MachineSSL -Machine $WorkerName -CertificateBaseName 'worker' -CommonName "kube-worker-${WorkerIP}" -IpAddresses $WorkerIP
    }
}
END{
    

}