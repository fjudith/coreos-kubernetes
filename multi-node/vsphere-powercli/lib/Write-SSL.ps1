PARAM(
	[parameter(mandatory=$True)][String]$OutputPath,
    [parameter(mandatory=$True)][String]$Name,
    [parameter(mandatory=$True)][String]$CommonName,
    [parameter(mandatory=$False)][String[]]$SubjectAlternativeName
)
BEGIN{
    $ErrorActionPreference = 'stop'

    $OpenSSLBinary = $(Get-Command -Type 'Application' -Name 'openssl').Path

    If(-not $(Test-Path -Path $OutputPath)){throw "Output directory path:`"$OutputPath`" does not exists."}

    $OutputFile = "${OutputPath}\$CommonName.zip"

    if(Test-Path -Path $OutputFile){
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

    $ConfigFile="${OutputPath}/${Name}-req.cnf"
    $CAFile="${OutputPath}/ca.pem"
    $CAKeyFile="${OutputPath}/ca-key.pem"
    $KeyFile="${OutputPath}/${Name}-key.pem"
    $CSRFile="${OutputPath}/${Name}.csr"
    $PEMFile="${OutputPath}/${Name}.pem"

    $Contents="${CAFile} ${KeyFile} ${PEMFile}"
}
PROCESS{
    
    # Add SANs to openssl config
    Write-Verbose -Message "Adding Suject Alternative Names:`"$SubjectAlternativeName`" to OpenSSL configuration file path:`"$ConfigFile`""
    Add-Content -Path $ConfigFile -Value $CNFTemplate
    Add-Content -Path $ConfigFile -Value $SubjectAlternativeName

    # Generate Key
    Write-Verbose -Message "Generating certificate key path:`"$KeyFile`" for `"$Name`""
    Start-Process -ErrorAction 'Stop' -Wait -WorkingDirectory $pwd -FilePath $OpenSSLBinary -ArgumentList (
        "genrsa",
        "-out",
        "`"$KeyFile`"",
        "2048"
    ) -NoNewWindow

    # Generate CSR
    Write-Verbose -Message "Generating certificate request path:`"$CSRFile`" for `"$Name`""
    Start-Process -ErrorAction 'Stop' -Wait -WorkingDirectory $pwd -FilePath $OpenSSLBinary -ArgumentList (
        "req",
        "-new",
        "-key `"$KeyFile`"",
        "-out `"$CSRFile`"",
        "-subj `"/CN=$CommonName`"",
        "-config `"$ConfigFile`""
    ) -NoNewWindow

    # Generate Certificate
    Write-Verbose -Message "Generating certificate path:`"$PEMFile`" for `"$Name`""
    Start-Process -ErrorAction 'Stop' -Wait -WorkingDirectory $pwd -FilePath $OpenSSLBinary -ArgumentList (
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
    Set-Content -path $OutputFile -value ("PK" + [char]5 + [char]6 + ("$([char]0)" * 18)) -ErrorAction 'Stop'
    $ZipFile = Get-Item $OutputFile -ErrorAction 'Stop'
    $ZipFile.IsReadOnly = $False
    $ShellApp = New-Object -ComObject 'shell.application'
    $ZipPackage = $ShellApp.NameSpace($ZipFile.FullName)
    $ZipPackage.CopyHere($(Get-Item -Path $CAFile).FullName)
    Start-sleep -milliseconds 500
    $ZipPackage.CopyHere($(Get-Item -Path $KeyFile).FullName)
    Start-sleep -milliseconds 500
    $ZipPackage.CopyHere($(Get-Item -Path $PEMFile).FullName)

}
END{
    Write-Output -InputObject $(Get-ChildItem -Path $OutputFile)
}