PARAM(
    [parameter(mandatory=$false)]
    [hashtable]
    $Server = @{
        'storage-host1' = '192.168.251.201' ;
        'storage-host2' = '192.168.251.202' ;
        'storage-host3' = '192.168.251.203' ;
    },

    # CoreOS Remote user
    [parameter(mandatory=$false)]
    [String]
    $User = 'core',

    [parameter(mandatory=$false)]
    [String]
    $Password,

    [parameter(mandatory=$false)]
    [String]$KeyFile = "${env:USERPROFILE}\.ssh\k8s-vsphere_id_rsa"
)
BEGIN{

    # Install/Load Posh-SSH
    If(-Not $(Get-Module -Name 'Posh-SSH') -and -Not $(Test-Path -Path "${env:USERPROFILE}\Documents\WindowsPowershell\Modules\Posh-SSH"))
    {
        New-Item -Force -ItemType 'Directory' -Path "${env:USERPROFILE}\Documents\WindowsPowershell\Modules" > $Null
        Invoke-WebRequest -Uri 'https://github.com/darkoperator/Posh-SSH/archive/master.zip' -OutFile "${env:TEMP}\Posh-SSH.zip"

        Expand-Archive -Path "${env:TEMP}\Posh-SSH.zip" -OutputPath "${env:USERPROFILE}\Documents\WindowsPowershell\Modules\" 
        Rename-Item -Path "${env:USERPROFILE}\Documents\WindowsPowershell\Modules\Posh-SSH-master" -NewName "Posh-SSH" -Force
    }
    Import-module -Force -Name 'Posh-SSH'

    # Create SSH Credential Object
    # Password will be used as the SSH key passphrase
    If($Password)
    {
        $SecureHostPassword = ConvertTo-SecureString "${Password}" -AsPlainText -Force
    }
    Else
    {
        # Empty Password
        $SecureHostPassword = (new-object System.Security.SecureString)
        
    }
    $Credential = New-Object System.Management.Automation.PSCredential ("${User}", $SecureHostPassword)
    

}
PROCESS{
    $Server.Keys | Foreach{
        $ComputerName = $Server[$_]
        $Files = Get-ChildItem -Path "${pwd}\$($_)\" -Exclude 'README.md'
        $SSHSessionID = $(New-SSHSession -ComputerName $ComputerName -Credential $Credential -KeyFile $KeyFile -Force).SessionID


        Foreach($File in $Files)
        {
            $SystemdUnit        = $File.Name -replace '(ceph)\-(\d{3})','$1\\x2d$2'
            
            Set-ScpFile  -Force -LocalFile $File -RemotePath "/tmp/" -ComputerName $Computername -Credential $Credential -KeyFile $KeyFile
            
            Invoke-SSHCommand -Index $SSHSessionID -Command "export TERM=xterm; sudo mv /tmp/$($File.Name) /etc/systemd/system/${SystemdUnit}"
            
            Invoke-SSHCommand -Index $SSHSessionID -Command "sudo systemctl enable ${SystemdUnit}"
        }
    }
}