PARAM(
    [parameter(mandatory=$false)][String]$VMHost,
    [parameter(mandatory=$false)][String]$Cluster ='Cluster-Prod',
    [parameter(mandatory=$false)][String]$ConfigurationPath = "${pwd}\conf",
    
    [parameter(mandatory=$false)][Switch]$Force,
    [parameter(mandatory=$false)][Switch]$Whatif
)
BEGIN
{
    $ErrorActionPreference = 'continue'

    Import-Module -Name 'VMware.VimAutomation.Core'
    
    If($Force){$Confirm = $False}
    Else{$Confirm = $True}
}
PROCESS
{
    Foreach($Item in $(Get-ChildItem -Path "${ConfigurationPath}\*\*"))
    {
        If($Whatif)
        {
            Write-Host -Object "$($Item.Name): Removing permanently"
            break
        }

        If($VMhost){$Object = $(Get-VMHost -Name $VMHost | Get-VM -Name $Item.Name -ErrorAction 'silentlycontinue')}
        ElseIf($Cluster){$Object = $(Get-Cluster -Name $Cluster | Get-VM -Name $Item.Name -ErrorAction 'silentlycontinue')}
        
        Write-Host -Object "$($Item.Name): Removing permanently"

        If($Object.PowerState -ne 'PoweredOff')
        {
            Stop-VM -VM $Object -Confirm:$Confirm
        }
        
        Remove-VM -DeletePermanently -VM $Object -Confirm:$Confirm
        Remove-Item -Recurse -Confirm:$Confirm -Path "${ConfigurationPath}\*\$($Item.Name)"
    }
}