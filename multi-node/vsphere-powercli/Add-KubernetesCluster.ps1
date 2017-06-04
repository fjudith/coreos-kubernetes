PARAM(
    [parameter(mandatory=$false)][String]$VMHost,
    [parameter(mandatory=$false)][String]$Cluster ='Cluster-Prod',
    [parameter(mandatory=$false)][String]$PortGroup = 'fre-server',
    [parameter(mandatory=$false)][String]$Datastore = 'FAS01_PROD_SATA_04',
    [parameter(mandatory=$false)][String]$DiskStorageFormat = 'thin',

    [parameter(mandatory=$false)][String]$UpdateChannel = 'beta',

    # Etcd configuration
    [parameter(mandatory=$false)][String]$EtcdNamePrefix = 'etcd',
    [parameter(mandatory=$false)][Int]$EtcdCount = 1,
    [parameter(mandatory=$false)][Int]$EtcdVMMemory = 512,
    [parameter(mandatory=$false)][String]$EtcdSubnet = '192.168.251.0',
    [parameter(mandatory=$false)][Int]$EtcdCIDR = 24,
    [parameter(mandatory=$false)][Int]$EtcdStartFrom = 50,
    [parameter(mandatory=$false)][String]$EtcdGateway = '192.168.251.254',

    # Kubernetes Controller configuration
    [parameter(mandatory=$false)][String]$ControllerNamePrefix = 'ctrl',
    [parameter(mandatory=$false)][Int]$ControllerCount = 1,
    [parameter(mandatory=$false)][Int]$ControllerVMMemory = 1024,
    [parameter(mandatory=$false)][String]$ControllerSubnet = '192.168.251.0',
    [parameter(mandatory=$false)][Int]$ControllerCIDR = 24,
    [parameter(mandatory=$false)][Int]$ControllerStartFrom = 100,
    [parameter(mandatory=$false)][String]$ControllerGateway = '192.168.251.254',

    # Kubernetes Worker configuration
    [parameter(mandatory=$false)][String]$WorkerNamePrefix = 'wrkr',
    [parameter(mandatory=$false)][Int]$WorkerCount = 1,
    [parameter(mandatory=$false)][Int]$WorkerVMMemory = 1024,
    [parameter(mandatory=$false)][Int]$WorkerVMCpu = 1,
    [parameter(mandatory=$false)][String]$WorkerSubnet = '192.168.251.0',
    [parameter(mandatory=$false)][Int]$WorkerCIDR = 24,
    [parameter(mandatory=$false)][Int]$WorkerStartFrom = 200,
    [parameter(mandatory=$false)][String]$WorkerGateway = '192.168.251.254',

    # Disk configuration
    [parameter(mandatory=$false)][Int]$NodeDisks = 3,
    [parameter(mandatory=$false)][Int]$DiskSize = 5,

    # CoreOS Remote user
    [parameter(mandatory=$false)][String]$SSHUser = 'k8s-vsphere',
    [parameter(mandatory=$false)][String]$SSHPassword = 'K8S-vsph3r3',

    # CoreOS host dns records
    [parameter(mandatory=$false)][string[]]$DnsServer = @(
        '192.168.1.1';
        '192.168.1.2'
    ),

    # Controller cluster IP
    [parameter(mandatory=$false)][String]$ControllerClusterIP = '10.3.0.1'
)
BEGIN{
    Set-StrictMode -Version 5

    $ErrorActionPreference = 'stop'

    # Import Powershell Module
    Import-Module -Name 'VMware.VimAutomation.Core'
    Import-Module -Force -Name "${pwd}\Modules\K8s-vSphere"
    Import-module -Force -Name "${pwd}\Modules\Posh-SSH"

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

    # Create SSH Credential Object
    $SecureHostPassword = ConvertTo-SecureString "${SSHPassword}" -AsPlainText -Force
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
        New-K8sEtcdCluster -VMhost $VMHost `
        -Subnet $EtcdSubnet -CIDR $EtcdCIDR -Gateway $EtcdGateway -DNS $DnsServer `
        -StartFrom $EtcdStartFrom -Count $EtcdCount -NamePrefix $EtcdNamePrefix `
        -DataStore $Datastore -PortGroup $PortGroup -DiskstorageFormat $DiskStorageFormat `
        -CloudConfigFile $EtcdCloudConfigFile
    }
    ElseIf($Cluster)
    {
        New-K8sEtcdCluster -Cluster $Cluster `
        -Subnet $EtcdSubnet -CIDR $EtcdCIDR -Gateway $EtcdGateway -DNS $DnsServer `
        -StartFrom $EtcdStartFrom -Count $EtcdCount -NamePrefix $EtcdNamePrefix `
        -DataStore $Datastore -PortGroup $PortGroup -DiskstorageFormat $DiskStorageFormat `
        -CloudConfigFile $EtcdCloudConfigFile
    }

    # Controller
    ##################################################

    if($VMHost)
    {
        New-K8sControllerCluster -VMhost $VMHost `
        -Subnet $ControllerSubnet -CIDR $ControllerCIDR -Gateway $ControllerGateway -DNS $DnsServer `
        -StartFrom $ControllerStartFrom -Count $ControllerCount -NamePrefix $ControllerNamePrefix `
        -DataStore $Datastore -PortGroup $PortGroup -DiskstorageFormat $DiskStorageFormat `
        -CloudConfigFile $ControllerCloudConfigFile -InstallScript $ControllerCloudConfigPath `
        -SSHCredential $SSHCredential
    }
    ElseIf($Cluster)
    {
        New-K8sControllerCluster -Cluster $Cluster `
        -Subnet $ControllerSubnet -CIDR $ControllerCIDR -Gateway $ControllerGateway -DNS $DnsServer `
        -StartFrom $ControllerStartFrom -Count $ControllerCount -NamePrefix $ControllerNamePrefix `
        -DataStore $Datastore -PortGroup $PortGroup -DiskstorageFormat $DiskStorageFormat `
        -CloudConfigFile $ControllerCloudConfigFile -InstallScript $ControllerCloudConfigPath `
        -SSHCredential $SSHCredential
    }

    # Worker
    ##################################################
    if($VMHost)
    {
        New-K8sWorkerCluster -VMhost $VMHost `
        -Subnet $WorkerSubnet -CIDR $WorkerCIDR -Gateway $WorkerGateway -DNS $DnsServer `
        -StartFrom $WorkerStartFrom -Count $WorkerCount -NamePrefix $WorkerNamePrefix `
        -DataStore $Datastore -PortGroup $PortGroup -DiskstorageFormat $DiskStorageFormat `
        -CloudConfigFile $WorkerCloudConfigFile -InstallScript $WorkerCloudConfigPath `
        -EtcdEndpoints $EtcdEndpoints `
        -SSHCredential $SSHCredential
    }
    ElseIf($Cluster)
    {
        New-K8sWorkerCluster -Cluster $Cluster `
        -Subnet $WorkerSubnet -CIDR $WorkerCIDR -Gateway $WorkerGateway -DNS $DnsServer `
        -StartFrom $WorkerStartFrom -Count $WorkerCount -NamePrefix $WorkerNamePrefix `
        -DataStore $Datastore -PortGroup $PortGroup -DiskstorageFormat $DiskStorageFormat `
        -CloudConfigFile $WorkerCloudConfigFile -InstallScript $WorkerCloudConfigPath `
        -EtcdEndpoints $EtcdEndpoints `
        -SSHCredential $SSHCredential
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