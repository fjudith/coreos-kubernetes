<#
.SYNOPSIS
Deploy a Kubernetes Cluster running on CoreOS Container Linux to a VMware vSphere Infrastructure.

.DESCRIPTION
The "Install-K8sCluster" command aims to deploy a fully design compliant Kubernetes Cluster running CoreOS Container Linux to a single VMware vSphere host or cluster.
The deployment procedure handles programmatically the creation of the following platform components.

1. Etcd host(s) for service discovery
2. Kubernetes Controller host(s) for cluster management
3. Kubernetes Worker node(s) for container execution

.PARAMETER VMhost
Specifies the host on which you want to create the CoreOS Container Linux virtual machines.

.PARAMETER Cluster
Specifies the Cluster on which you want to create to CoreOS Container Linux virtual machines.

.PARAMETER PortGroup
Specifies the default virtual port-group to allocate to all CoreOS Container Linux virtual machines.
i.e. ETCd, Kubernetes Controller and Kubernetes Worker.

.PARAMETER Datastore
Specifies the default datastore to allocate to all CoreOS Container Linux virtual machines.
i.e. ETCd, Kubernetes Controller and Kubernetes Worker.

.PARAMETER DiskStorageFormat
Specifies te default storage format configurer on all CoreOS Container Linux virtual machines disks.

.PARAMETER UpdateChannel
Specifies the operating system release used to create the CoreOS Container Linux virtual machines.
i.e. 'stable', 'beta', 'alpha'

Caution : 'alpha' channel Docker version is not yet supported by Kubernetes. 

.PARAMETER SSHUser
Specifies the user name used to open SSH sessions to Core Container Linux hots.

.PARAMETER SSHPassword
Specifies the user password used to open SSH sessions to Core Container Linux hots.

.PARAMETER DnsServer
Specifies the list of DNS Server to be configured in the host ip configuration.

.PARAMETER ControllerClusterIP
Specifies the Kubernetes controller cluster IP

.PARAMETER ControllerEndPoint
Specifies the Controller end-point URL.
Typically load balancer/reverse-proxy w/o ssl offloading or DNS host A record(s)
e.g https://k8s.example.com

.PARAMETER EtcdNamePrefix
Specifies the prefix ETCd virtual machine names and hostnames.
Naming convention: <prefix><nnn>
Result:            etc001,etc002,etc003

.PARAMETER EtcdPortGroup
Specifies the vSphere virtual port-group allocated to ETCd virtual machines.

.PARAMETER EtcdDatastore
Specifies the vSphere datastore allocated to ETCd virtual machines.
The default behavior is to store all etcd hosts.
It is recommended to redistribute them in seperated datastore using storage vmotion to enhance fault tolerance.

.PARAMETER EtcdCount
Specifies the number of ETCd virtual machine to deploy

.PARAMETER EtcdVMMemory
Specifies the amount of RAM to allocated to ETCd virtual machines.

.PARAMETER EtcdVMCpu
Specifies the amount of CPU to allocated to ETCd virtual machines.

.PARAMETER EtcdSubnet
Specifies the Subnet allocated to ETCd hosts.

.PARAMETER EtcdCIDR
Specifies the network mask CIDR of ETCd subnet.

.PARAMETER EtcdStartFrom
Specifies the number where the ip address generation starts for ETCd host.

.PARAMETER EtcdGateway
Specifies the default gateway ip address of ETCd hosts.

#>
PARAM(
    # vSphere Common Spec
    [parameter(mandatory=$false)][String]$VMHost,
    [parameter(mandatory=$false)][String]$Cluster ='Cluster-Prod',
    [parameter(mandatory=$false)][String]$PortGroup = 'fre-server',
    [parameter(mandatory=$false)][String]$Datastore = 'FAS01_PROD_SATA_04',
    [parameter(mandatory=$false)][String]$DiskStorageFormat = 'thin',

    [parameter(mandatory=$false)][String]$UpdateChannel = 'stable',

    # CoreOS Remote user
    [parameter(mandatory=$false)][String]$SSHUser = 'core',
    [parameter(mandatory=$false)][String]$SSHPassword,

    # CoreOS host dns records
    [parameter(mandatory=$false)][string[]]$DnsServer = @(
        '192.168.1.1';
        '192.168.1.2'
    ),

    # Controller cluster IP
    [parameter(mandatory=$false)][String]$ControllerClusterIP = '10.3.0.1',

    # Controller Endpoint
    [parameter(mandatory=$false)][String]$ControllerEndPoint,

    # Etcd configuration
    [parameter(mandatory=$false)][String]$EtcdNamePrefix = 'etcd',
    [parameter(mandatory=$false)][String]$EtcdPortgroup = $PortGroup,
    [parameter(mandatory=$false)][String]$EtcdDatastore = $Datastore,
    [parameter(mandatory=$false)][Int]$EtcdCount = 1,
    [parameter(mandatory=$false)][Int]$EtcdVMMemory = 512,
    [parameter(mandatory=$false)][Int]$EtcdVMCpu = 1,
    [parameter(mandatory=$false)][String]$EtcdSubnet = '192.168.251.0',
    [parameter(mandatory=$false)][Int]$EtcdCIDR = 24,
    [parameter(mandatory=$false)][Int]$EtcdStartFrom = 50,
    [parameter(mandatory=$false)][String]$EtcdGateway = '192.168.251.254',


    # Kubernetes Controller configuration
    [parameter(mandatory=$false)][String]$ControllerNamePrefix = 'ctrl',
    [parameter(mandatory=$false)][String]$ControllerPortGroup = $PortGroup,
    [parameter(mandatory=$false)][String]$ControllerDatastore = $Datastore,
    [parameter(mandatory=$false)][Int]$ControllerCount = 1,
    [parameter(mandatory=$false)][Int]$ControllerVMMemory = 1024,
    [parameter(mandatory=$false)][Int]$ControllerVMCpu = 1,
    [parameter(mandatory=$false)][String]$ControllerSubnet = '192.168.251.0',
    [parameter(mandatory=$false)][Int]$ControllerCIDR = 24,
    [parameter(mandatory=$false)][Int]$ControllerStartFrom = 100,
    [parameter(mandatory=$false)][String]$ControllerGateway = '192.168.251.254',
    [parameter(mandatory=$false)][string[]]$ControllerHardDisk = @(2GB ; 4GB ; 6GB),

    # Kubernetes Worker configuration
    [parameter(mandatory=$false)][String]$WorkerNamePrefix = 'wrkr',
    [parameter(mandatory=$false)][String]$WorkerPortGroup = $PortGroup,
    [parameter(mandatory=$false)][String]$WorkerDatastore = $Datastore,
    [parameter(mandatory=$false)][Int]$WorkerCount = 1,
    [parameter(mandatory=$false)][Int]$WorkerVMMemory = 1024,
    [parameter(mandatory=$false)][Int]$WorkerVMCpu = 1,
    [parameter(mandatory=$false)][String]$WorkerSubnet = '192.168.251.0',
    [parameter(mandatory=$false)][Int]$WorkerCIDR = 24,
    [parameter(mandatory=$false)][Int]$WorkerStartFrom = 200,
    [parameter(mandatory=$false)][String]$WorkerGateway = '192.168.251.254',
    [parameter(mandatory=$false)][string[]]$ControllerHardDisk = @(4GB ; 8GB ; 16GB)
)
BEGIN{
    Set-StrictMode -Version 5

    $ErrorActionPreference = 'stop'

    # Load Machine configuration from config
    $Config = ([System.IO.FileInfo]"${pwd}\config.ps1").FullName
    If (Test-Path $Config)
    {   
        # Get config file content, remove empty lines and invoke each line
        Get-Content -Path $Config | ? {$_.trim() -ne "" } | Invoke-Expression
    }

    If ($WorkerVMMemory -le 1024)
    {
        Write-Warning -Message 'Workers should have at least 1024 MB of Memory'
    }

    # Import Powershell Module
    # VMware vSphere PowerCLI
    Import-Module -Name 'VMware.VimAutomation.Core'

    # K8s-vSphere
    Import-Module -Force -Name "${pwd}\Modules\K8s-vSphere"

    # Posh-SSH
    If(-Not $(Get-Module -Name 'Posh-SSH') -and -Not $(Test-Path -Path "${env:USERPROFILE}\Documents\WindowsPowershell\Modules\Posh-SSH"))
    {
        New-Item -Force -ItemType 'Directory' -Path "${env:USERPROFILE}\Documents\WindowsPowershell\Modules" > $Null
        Invoke-WebRequest -Uri 'https://github.com/darkoperator/Posh-SSH/archive/master.zip' -OutFile "${env:TEMP}\Posh-SSH.zip"

        Expand-Archive -Path "${env:TEMP}\Posh-SSH.zip" -OutputPath "${env:USERPROFILE}\Documents\WindowsPowershell\Modules\" 
        Rename-Item -Path "${env:USERPROFILE}\Documents\WindowsPowershell\Modules\Posh-SSH-master" -NewName "Posh-SSH" -Force
    }
    Import-module -Force -Name 'Posh-SSH'

    # Create SSH Key
    Write-K8sSSHkey -Outfile "${env:USERPROFILE}\.ssh\k8s-vsphere_id_rsa" -Passphrase $SSHPassword
    $SSHPrivateKeyFile = "${env:USERPROFILE}\.ssh\k8s-vsphere_id_rsa"
    $SSHPublicKeyFile = "${env:USERPROFILE}\.ssh\k8s-vsphere_id_rsa.pub"

    # Create SSH Credential Object
    # Password will be used as the SSH key passphrase
    If($SSHPassword)
    {
        $SecureHostPassword = ConvertTo-SecureString "${SSHPassword}" -AsPlainText -Force
    }
    Else
    {
        # Empty Password
        $SecureHostPassword = (new-object System.Security.SecureString)
        
    }
    $SSHCredential = New-Object System.Management.Automation.PSCredential ("${SSHUser}", $SecureHostPassword) 

    $EtcdCloudConfigFile = ([System.IO.FileInfo]"${pwd}\etcd-cloud-config.yaml").FullName
    $ControllerCloudConfigFile = ([System.IO.FileInfo]"${pwd}\controller-cloud-config.yaml").FullName
    $WorkerCloudConfigFile = ([System.IO.FileInfo]"${pwd}\worker-cloud-config.yaml").FullName

    $ControllerCloudConfigPath = ([System.IO.FileInfo]"${pwd}\..\generic\controller-install.sh").FullName
    $WorkerCloudConfigPath = ([System.IO.FileInfo]"${pwd}\..\generic\worker-install.sh").FullName

    # Building array of Etcd IP addresses as per given etcd count
    $EtcdIPs = Get-K8sEtcdIP -Subnet $EtcdSubnet -StartFrom $EtcdStartFrom -Count $EtcdCount

    # Building a single string for Etcd Cluster Node list containing Etcd hostnames and URLs as per given etcd count
    $InitialEtcdCluster = Get-K8sEtcdInitialCluster -NamePrefix $EtcdNamePrefix -IpAddress $EtcdIPs

    # Building a single string for Etcd Endpoints Node list containing Etcd URLs as per given etcd count
    $EtcdEndpoints = Get-K8sEtcdEndpoint -IpAddress $EtcdIPs -Protocol 'http' -Port '2379'

    # Building array of Controller IP addresses as per given controller count
    # Adding Controller Cluster IP address at the end of the list
    $ControllerIPs = Get-K8sControllerIP -Subnet $ControllerSubnet -StartFrom $ControllerStartFrom -Count $ControllerCount -ControllerCluster $ControllerClusterIP

    # Automatically select fisrt controller as worker endpoint 
    # If no controller endpoint provided in argument
    If(-not $ControllerEndpoint){
        $ControllerEndpoint = "https://$($ControllerIPs | Select-Object -First 1)"
    }

    # Building array of Worker IP addresses as per given worker count
    $WorkerIPs = Get-K8sWorkerIP -Subnet $WorkerSubnet -StartFrom $WorkerStartFrom -Count $WorkerCount
}  
PROCESS{
    
    # Root CA
    ##################################################
    Write-Verbose -Message "Generating Root CA"
    
    New-Item -Force -Type 'Directory' -Path "${pwd}\ssl" > $Null
    Write-K8sCACertificate -OutputPath "${pwd}\ssl"

    # Admin certificate
    ##################################################
    Write-Verbose -Message "Admin certficicate"
    
    Write-K8sCertificate -OutputPath "${pwd}\ssl" -Name 'admin' -CommonName 'kube-admin'

    # OVA Download
    ##################################################
    $OVAPath = "${pwd}\.ova\coreos_production_vmware_ova.ova"
    
    Update-CoreOs -UpdateChannel $UpdateChannel -Destination $OVAPath

    # Etcd
    ##################################################
    if($VMHost)
    {
        New-K8sEtcdCluster -VMhost $VMHost -MemoryMB $EtcdVMMemory -numCPU $EtcdVMCpu `
        -Subnet $EtcdSubnet -CIDR $EtcdCIDR -Gateway $EtcdGateway -DNS $DnsServer `
        -StartFrom $EtcdStartFrom -Count $EtcdCount -NamePrefix $EtcdNamePrefix `
        -DataStore $EtcdDatastore -PortGroup $EtcdPortGroup -DiskstorageFormat $DiskStorageFormat `
        -CloudConfigFile $EtcdCloudConfigFile -SSHPublicKeyFile $SSHKey[1].FullName
    }
    ElseIf($Cluster)
    {
        New-K8sEtcdCluster -Cluster $Cluster -MemoryMB $EtcdVMMemory -numCPU $EtcdVMCpu `
        -Subnet $EtcdSubnet -CIDR $EtcdCIDR -Gateway $EtcdGateway -DNS $DnsServer `
        -StartFrom $EtcdStartFrom -Count $EtcdCount -NamePrefix $EtcdNamePrefix `
        -DataStore $EtcdDatastore -PortGroup $EtcdPortGroup -DiskstorageFormat $DiskStorageFormat `
        -CloudConfigFile $EtcdCloudConfigFile -SSHPublicKeyFile $SSHPublicKeyFile
    }

    # Controller
    ##################################################

    if($VMHost)
    {
        New-K8sControllerCluster -VMhost $VMHost -MemoryMB $ControllerVMMemory -numCPU $ControllerVMCpu -HardDisk $ControllerHardDisk `
        -Subnet $ControllerSubnet -CIDR $ControllerCIDR -Gateway $ControllerGateway -DNS $DnsServer `
        -StartFrom $ControllerStartFrom -Count $ControllerCount -NamePrefix $ControllerNamePrefix `
        -DataStore $ControllerDatastore -PortGroup $ControllerPortGroup -DiskstorageFormat $DiskStorageFormat `
        -CloudConfigFile $ControllerCloudConfigFile -InstallScript $ControllerCloudConfigPath `
        -EtcdEndpoints $EtcdEndpoints -ControllerCluster $ControllerClusterIP -ControllerEndpoint $ControllerEndpoint `
        -SSHCredential $SSHCredential -SSHPrivateKeyFile $SSHPrivateKeyFile -SSHPublicKeyFile $SSHPublicKeyFile
    }
    ElseIf($Cluster)
    {
        New-K8sControllerCluster -Cluster $Cluster -MemoryMB $ControllerVMMemory -numCPU $ControllerVMCpu -HardDisk $ContorllerHardDisk `
        -Subnet $ControllerSubnet -CIDR $ControllerCIDR -Gateway $ControllerGateway -DNS $DnsServer `
        -StartFrom $ControllerStartFrom -Count $ControllerCount -NamePrefix $ControllerNamePrefix `
        -DataStore $ControllerDatastore -PortGroup $ControllerPortGroup -DiskstorageFormat $DiskStorageFormat `
        -CloudConfigFile $ControllerCloudConfigFile -InstallScript $ControllerCloudConfigPath `
        -EtcdEndpoints $EtcdEndpoints -ControllerCluster $ControllerClusterIP -ControllerEndpoint $ControllerEndpoint `
        -SSHCredential $SSHCredential -SSHPrivateKeyFile $SSHPrivateKeyFile -SSHPublicKeyFile $SSHPublicKeyFile
    }

    # Worker
    ##################################################
    if($VMHost)
    {
        New-K8sWorkerCluster -VMhost $VMHost -MemoryMB $WorkerVMMemory -numCPU $WorkerVMCpu -HardDisk $WorkderHardDisk `
        -Subnet $WorkerSubnet -CIDR $WorkerCIDR -Gateway $WorkerGateway -DNS $DnsServer `
        -StartFrom $WorkerStartFrom -Count $WorkerCount -NamePrefix $WorkerNamePrefix `
        -DataStore $WorkerDatastore -PortGroup $WorkerPortGroup -DiskstorageFormat $DiskStorageFormat `
        -CloudConfigFile $WorkerCloudConfigFile -InstallScript $WorkerCloudConfigPath `
        -EtcdEndpoints $EtcdEndpoints -ControllerEndpoint $ControllerEndpoint `
        -SSHCredential $SSHCredential -SSHPrivateKeyFile $SSHPrivateKeyFile -SSHPublicKeyFile $SSHPublicKeyFile
    }
    ElseIf($Cluster)
    {
        New-K8sWorkerCluster -Cluster $Cluster -MemoryMB $WorkerVMMemory -numCPU $WorkerVMCpu -HardDisk $HardDisk `
        -Subnet $WorkerSubnet -CIDR $WorkerCIDR -Gateway $WorkerGateway -DNS $DnsServer `
        -StartFrom $WorkerStartFrom -Count $WorkerCount -NamePrefix $WorkerNamePrefix `
        -DataStore $WorkerDatastore -PortGroup $WorkerPortGroup -DiskstorageFormat $DiskStorageFormat `
        -CloudConfigFile $WorkerCloudConfigFile -InstallScript $WorkerCloudConfigPath `
        -EtcdEndpoints $EtcdEndpoints -ControllerEndpoint $ControllerEndpoint `
        -SSHCredential $SSHCredential -SSHPrivateKeyFile $SSHPrivateKeyFile -SSHPublicKeyFile $SSHPublicKeyFile
    }
}
END{
    # Update kubeconfig with the first controller ip
    $ControllerExternalIP = $ControllerIPs | Select-Object -First 1

    Write-Host -ForegroundColor 'cyan' -Object "
    Wait 15 minutes for the Kubernetes to initialize.
    Then execute the following commands to access your cluster
    "

    Write-Host -ForegroundColor 'cyan' -Object '
    $env:KUBECONFIG = "${pwd}/kubeconfig"
    '

    Write-Host -ForegroundColor 'cyan' -Object "
    .\kubectl.exe config use-context vsphere-multi
    .\kubectl.exe config set-cluster vsphere-multi-cluster --server=https://${ControllerExternalIP}:443 --certificate-authority=${pwd}/ssl/ca.pem
    .\kubectl.exe config set-credentials vsphere-multi-admin --certificate-authority=${pwd}/ssl/ca.pem --client-key=${pwd}/ssl/admin-key.pem --client-certificate=${pwd}/ssl/admin.pem
    .\kubectl.exe config set-context vphere-multi --cluster=vphere-multi-cluster --user=vsphere-multi-admin
    .\kubectl.exe config use-context vphere-multi
    .\kubectl.exe get nodes
    "

}