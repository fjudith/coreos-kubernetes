PARAM(
    [parameter(mandatory=$false)]
    [hashtable]
    Server = @{
        'storage-host1' = '192.168.251.201' ;
        'storage-host2' = '192.168.251.202' ;
        'storage-host3' = '192.168.251.203' ;
    }

    # CoreOS Remote user
    [parameter(mandatory=$false)]
    [String]
    $User = 'core',

    [parameter(mandatory=$false)]
    [String]
    $Password,

    [parameter(mandatory=$false)]
    [String]$KeyFile = "${env:USERPROFILE}",
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

}
PROCESS{
    $Server.Keys | foreach{
        $ComputerName = $Server[$_]
        $Files = Get-ChildItem -Path "${pwd}\$($_)\"

        Foreach($File in $Files)
        {
            Set-ScpFile  -Force -LocalFile $File -RemotePath '/tmp/' -ComputerName $Computername -Credential $SSHCredential -KeyFile $SSHKeyFile
        }

        $vmx += "$($_) = $($GuestInfo[$_])" + "`n"

    }
}