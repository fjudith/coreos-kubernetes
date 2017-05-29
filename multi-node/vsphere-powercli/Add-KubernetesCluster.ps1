PARAM(
    [parameter(mandatory=$false)][String]$UpdateChannel = 'beta',

    # Kubernetes Controller configuration
    [parameter(mandatory=$false)][Int]$ControllerCount = 3,
    [parameter(mandatory=$false)][Int]$ControllerVMMemory = 2048,

    # Kubernetes Worker configuration
    [parameter(mandatory=$false)][Int]$WorkerCount = 6,
    [parameter(mandatory=$false)][Int]$WorkerVMMemory = 2048,
    [parameter(mandatory=$false)][Int]$WorkerVMCpu = 1,

    # Etcd configuration
    [parameter(mandatory=$false)][Int]$EtcdCount = 3,
    [parameter(mandatory=$false)][Int]$EtcdVMMemory = 512,

    # Disk configuration
    [parameter(mandatory=$false)][Int]$NodeDisks = 3,
    [parameter(mandatory=$false)][Int]$DiskSize = 5
)
BEGIN{
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

    Function Get-EtcdIP([int]$Number){
        Write-Output -InputObject "172.17.4.$($Number + 50)"
    }

    Function Get-ControllerIP([int]$Number){
        Write-Output -InputObject "172.17.4.$($Number + 100)"
    }

    Function Get-WorkerIP([int]$Number){
        Write-Output -InputObject "172.17.4.$($Number + 200)"
    }

    # Building array of Controller IP addresses as per given controller count
    # Adding Controller Cluster IP address at the end of the list
    $ControllerIPs = @()
    For($i =1 ; $i -le $ControllerCount; $i++){$ControllerIPs += Get-ControllerIP -Number $i}
    $ControllerIPs += $ControllerClusterIP
    Write-Verbose -Message "Controller IPs:`"$ControllerIPs`""

    # Building array of Etcd IP addresses as per given etcd count
    $EtcdIPs = @()
    For($i = 1 ; $i -le $EtcdCount; $i++){$EtcdIPs += Get-EtcdIP -Number $i}
    

    # Building a single string for Etcd Cluster Node list containing Etcd hostnames and URLs as per given etcd count
    $InitialEtcdCluster = @()
    For($i = 0 ; $i -lt $EtcdIPs.Length; $i++){$InitialEtcdCluster += "e$($i +1)=http://$($EtcdIPs[$i]):2380"}
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
        
        .\Lib\Write-SSL.ps1 -OutputPath "$(pwd)\ssl" -Name "${CertificateBaseName}" -CommonName "${CommonName}" -SubjectAlternativeName $IpString
    }
}  
PROCESS{
    
    # Root CA
    ##################################################
    Write-Verbose -Message "Generating Root CA"
    New-Item -Force -Type 'Directory' -Path "${pwd}\ssl"
    .\Lib\Write-SSLCA.ps1 -OutputPath "${pwd}\ssl"

    # Admin certificate
    ##################################################
    Write-Verbose -Message "Admin certficicate"
    .\Lib\Write-SSL.ps1 -OutputPath "$(pwd)\ssl" -Name 'admin' -CommonName 'kube-admin'

    # OVA Download
    $OVAPath = ".\.ova\coreos_production_vmware_ova.ova"
    If(-Not $(Test-Path $OVAPath)){
        $FileInfo = [System.IO.FileInfo]$OVAPath
        New-Item -Force -ItemType 'Directory' -Path  $($File.Directory)

        Invoke-WebRequest -Uri "https://${UpdateChannel}.release.core-os.net/amd64-usr/current/coreos_production_vmware_ova.ova" -OutFile $OVAPath
    }

    # Controller
    ##################################################
    Write-Verbose -Message "Controller certificates"
    For($i = 0; $i -lt $ControllerCount; $i++){
        $ControllerName = "k8scon$("{0:D3}" -f $($i +1))"
        $ControllerIP = Get-ControllerIP -Number $($i +1)

        Write-MachineSSL -Machine $ControllerName -CertificateBaseName 'apiserver' -CommonName "kube-apiserver-${ControllerIP}" -IpAddresses $ControllerIPs
    }

    # Worker
    ##################################################
    Write-Verbose -Message "Worker certificates"
    For($i = 0; $i -lt $WorkerCount; $i++){
        $WorkerName = "k8scon$("{0:D3}" -f $($i +1))"
        $WorkerIP = Get-WorkerIP -Number $($i +1)

        Write-MachineSSL -Machine $WorkerName -CertificateBaseName 'worker' -CommonName "kube-worker-${WorkerIP}" -IpAddresses $WorkerIP
    }
}
END{
    

}