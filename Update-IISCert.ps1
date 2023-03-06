$IISDomain = '{DOMAIN}';
$IISSite = 'Default Web Site';

[string] $Now = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss');
Write-Host "Running at $Now";

#Set-PAServer LE_TEST
Set-PAServer LE_PROD
Set-PAOrder -MainDomain $IISDomain;

if ($NewCert = Submit-Renewal -Verbose)
{
    $NewCert | Set-IISCertificate -SiteName $IISSite -Verbose -RemoveOldCert;
}
else { Write-Host 'Certificate renewal failed, or was not needed.'; }
Write-Host 'Done!';