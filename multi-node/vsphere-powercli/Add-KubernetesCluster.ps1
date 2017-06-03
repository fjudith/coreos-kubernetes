PARAM(
    [parameter(mandatory=$false)][String]$VMHost,
    [parameter(mandatory=$false)][String]$Cluster ='Cluster-Prod',
    [parameter(mandatory=$false)][String]$PortGroup = 'fre-server',
    [parameter(mandatory=$false)][String]$Datastore = 'FAS01_PROD_SATA_04',
    [parameter(mandatory=$false)][String]$DiskStorageFormat = 'thin',

    [parameter(mandatory=$false)][String]$UpdateChannel = 'beta',

    # Etcd configuration
    [parameter(mandatory=$false)][String]$EtcdNamePrefix = 'etcd',
    [parameter(mandatory=$false)][Int]$EtcdCount = 3,
    [parameter(mandatory=$false)][Int]$EtcdVMMemory = 512,
    [parameter(mandatory=$false)][String]$EtcdSubnet = '192.168.251.0',
    [parameter(mandatory=$false)][Int]$EtcdCIDR = 24,
    [parameter(mandatory=$false)][Int]$EtcdStartFrom = 50,
    [parameter(mandatory=$false)][String]$EtcdGateway = '192.168.251.254',

    # Kubernetes Controller configuration
    [parameter(mandatory=$false)][String]$ControllerNamePrefix = 'ctrl',
    [parameter(mandatory=$false)][Int]$ControllerCount = 3,
    [parameter(mandatory=$false)][Int]$ControllerVMMemory = 2048,
    [parameter(mandatory=$false)][String]$ControllerSubnet = '192.168.251.0',
    [parameter(mandatory=$false)][Int]$ControllerCIDR = 24,
    [parameter(mandatory=$false)][Int]$ControllerStartFrom = 100,
    [parameter(mandatory=$false)][String]$ControllerGateway = '192.168.251.254',

    # Kubernetes Worker configuration
    [parameter(mandatory=$false)][String]$WorkerNamePrefix = 'wrkr',
    [parameter(mandatory=$false)][Int]$WorkerCount = 6,
    [parameter(mandatory=$false)][Int]$WorkerVMMemory = 2048,
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

    # DNS Records
    [parameter(mandatory=$false)][string[]]$DnsServer = @(
        '192.168.1.1';
        '192.168.1.2'
    ),

    [parameter(mandatory=$false)][String]$ControllerClusterIP = "10.3.0.1"
)
BEGIN{
    Set-StrictMode -Version 5

    $ErrorActionPreference = 'stop'

    # Import Powershell Module
    Import-Module -Name 'VMware.VimAutomation.Core'
    Connect-Viserver 'vcenter.economat.local' -User 'fjudith@economat.local' -Password 'Dj43l1ss.03'
    Import-Module -Name "${pwd}\Modules\K8s-vSphere"
    Import-module -Name "${pwd}\Modules\Posh-SSH"

    # Create SSH Credential Object
    $SecureHostPassword = ConvertTo-SecureString "${SSHPassword}" -AsPlainText -Force
    $SSHCredential = New-Object System.Management.Automation.PSCredential ("${SSHUser}", $SecureHostPassword)

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

    $EtcdCloudConfigFile = ([System.IO.FileInfo]"${pwd}\etcd-cloud-config.yaml").FullName
    $ControllerCloudConfigFile = ([System.IO.FileInfo]"${pwd}\controller-cloud-config.yaml").FullName
    $WorkerCloudConfigFile = ([System.IO.FileInfo]"${pwd}\worker-cloud-config.yaml").FullName

    $ControllerCloudConfigPath = ([System.IO.FileInfo]"${pwd}\..\generic\controller-install.sh").FullName
    $WorkerCloudConfigPath = ([System.IO.FileInfo]"${pwd}\..\generic\worker-install.sh").FullName

    
    # Building array of Etcd IP addresses as per given etcd count
    $EtcdIPs = Get-K8sEtcdIP -Subnet $EtcdSubnet -StartFrom $EtcdStartFrom -Count $EtcdCount
    
    Write-Host -NoNewline -Object "Etcd IP Adresses ["
    Write-Host -NoNewline -ForegroundColor 'green' -Object "${EtcdIPs}"
    Write-Host -Object "]"


    # Building a single string for Etcd Cluster Node list containing Etcd hostnames and URLs as per given etcd count
    $InitialEtcdCluster = Get-K8sEtcdInitialCluster -NamePrefix $EtcdNamePrefix -IpAddress $EtcdIPs

    Write-Host -NoNewline -Object "Initial etcd cluster ["
    Write-Host -NoNewline -ForegroundColor 'green' -Object "${InitialEtcdCluster}"
    Write-Host -Object "]"


    # Building a single string for Etcd Endpoints Node list containing Etcd URLs as per given etcd count
    $EtcdEndpoints = Get-K8sEtcEndpoints -IpAddress $EtcdIPs -Protocol 'http' -Port '2379'

    Write-Host -NoNewline -Object "Etcd endpoints ["
    Write-Host -NoNewline -ForegroundColor 'green' -Object "${EtcdEndpoints}"
    Write-Host -Object "]"

    # Building array of Controller IP addresses as per given controller count
    # Adding Controller Cluster IP address at the end of the list
    $ControllerIPs = Get-K8sControllerIP -Subnet $ControllerSubnet -StartFrom $StartFrom -Count $ControllerCount -ControllerCluster $ControllerClusterIP
    
    Write-Host -NoNewline -Object "Controller IP Adresses ["
    Write-Host -NoNewline -ForegroundColor 'green' -Object "${ControllerIPs}"
    Write-Host -Object "]"


    Function Send-SSHMachineSSL(
        [string]$Machine, [string]$CertificateBaseName, [String]$CommonName, [String[]]$IpAddresses,[String]$Computername,[int]$SSHSession){
        $ZipFile = "${pwd}/${CommonName}"
        $IPString = @()
        For($i = 0 ; $i -lt $IpAddresses.Length; $i++){$IPString += "IP.$($i +1) = $($IpAddresses[$i])"}
        
        Write-K8sCertificate -OutputPath "${pwd}\ssl" -Name "${CertificateBaseName}" -CommonName "${CommonName}" -SubjectAlternativeName $IpString

        Set-ScpFile  -Force -LocalFile "${pwd}\ssl\${CommonName}.zip" -RemotePath '/tmp/' -ComputerName $Computername -Credential $SSHCredential
        Invoke-SSHCommand -SessionId $SSHSession -Command "sudo mkdir -p /etc/kubernetes/ssl && sudo unzip -o -e /tmp/${CommonName}.zip -d /etc/kubernetes/ssl"
    }
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
    if($VMHost){
        New-K8sEtcdCluster -VMhost $VMHost `
        -Subnet $EtcdSubnet -CIDR $EctdCIDR -Gateway $EtcdGateway -DNS $DnsServer `
        -StartFrom 50 -Count $EtcdCount -NamePrefix $EtcdNamePrefix `
        -DataStore $Datastore -PortGroup $PortGroup -DiskstorageFormat $DiskStorageFormat `
        -CloudConfigFile -$EtcdCloudConfigFile
    }
    ElseIf($Cluster){
        New-K8sEtcdCluster -Cluster $Cluster `
        -Subnet $EtcdSubnet -CIDR $EctdCIDR -Gateway $EtcdGateway -DNS $DnsServer `
        -StartFrom 50 -Count $EtcdCount -NamePrefix $EtcdNamePrefix `
        -DataStore $Datastore -PortGroup $PortGroup -DiskstorageFormat $DiskStorageFormat `
        -CloudConfigFile -$EtcdCloudConfigFile
    }

    # Controller
    ##################################################
    if($VMHost){
        New-K8sControllerCluster -VMhost $VMHost `
        -Subnet $ControllerSubnet -CIDR $EctdCIDR -Gateway $ControllerGateway -DNS $DnsServer `
        -StartFrom 100 -Count $ControllerCount -NamePrefix $ControllerNamePrefix `
        -DataStore $Datastore -PortGroup $PortGroup -DiskstorageFormat $DiskStorageFormat `
        -CloudConfigFile -$ControllerCloudConfigFile -InstallScript $ControllerCloudConfigPath
    }
    ElseIf($Cluster){
        New-K8sControllerCluster -Cluster $Cluster `
        -Subnet $ControllerSubnet -CIDR $EctdCIDR -Gateway $ControllerGateway -DNS $DnsServer `
        -StartFrom 100 -Count $ControllerCount -NamePrefix $ControllerNamePrefix `
        -DataStore $Datastore -PortGroup $PortGroup -DiskstorageFormat $DiskStorageFormat `
        -CloudConfigFile -$ControllerCloudConfigFile -InstallScript $ControllerCloudConfigPath
    }

    # Workder
    ##################################################
    if($VMHost){
        New-K8sWorkderCluster -VMhost $VMHost `
        -Subnet $WorkderSubnet -CIDR $EctdCIDR -Gateway $WorkderGateway -DNS $DnsServer `
        -StartFrom 100 -Count $WorkderCount -NamePrefix $WorkderNamePrefix `
        -DataStore $Datastore -PortGroup $PortGroup -DiskstorageFormat $DiskStorageFormat `
        -CloudConfigFile -$WorkderCloudConfigFile -InstallScript $WorkerCloudConfigPath `
        -EtcdEndpoints $EtcdEndpoints
    }
    ElseIf($Cluster){
        New-K8sWorkderCluster -Cluster $Cluster `
        -Subnet $WorkderSubnet -CIDR $EctdCIDR -Gateway $WorkderGateway -DNS $DnsServer `
        -StartFrom 100 -Count $WorkderCount -NamePrefix $WorkderNamePrefix `
        -DataStore $Datastore -PortGroup $PortGroup -DiskstorageFormat $DiskStorageFormat `
        -CloudConfigFile -$WorkderCloudConfigFile -InstallScript $WorkerCloudConfigPath `
        -EtcdEndpoints $EtcdEndpoints
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