PARAM(
    [parameter(mandatory=$True)]
    [String]
    $OutputPath
)
BEGIN{
    $ErrorActionPreference = 'stop'

    $OpenSSLBinary = $(Get-Command -Type 'Application' -Name 'openssl').Path

    If(-not $(Test-Path -Path $OutputPath)){throw "Output directory path:`"$OutputPath`" does not exists."}

    $OutputFile = "${OutputPath}\ca.pem"

    if(Test-Path -Path $OutputFile){
        Write-Verbose -Message "CA Certificate already exists. Nothing to do."
        Break
    }   
}
PROCESS{
    
    Start-Process -ErrorAction 'Stop' -Wait -WorkingDirectory $pwd -FilePath $OpenSSLBinary -ArgumentList (
        "genrsa",
        "-out",
        "`"$OutputPath\ca-key.pem`"",
        "2048"
    ) -NoNewWindow

    Start-Process -ErrorAction 'Stop' -Wait -WorkingDirectory $pwd -FilePath $OpenSSLBinary -ArgumentList (
        "req",
        "-x509",
        "-new",
        "-nodes",
        "-key `"$OutputPath\ca-key.pem`"",
        "-days 10000",
        "-out `"$OutputFile`"",
        "-subj `"/CN=kube-ca`""
    ) -NoNewWindow
}
END{
    Write-Output -InputObject $(Get-ChildItem -Path $OutputPath)
}