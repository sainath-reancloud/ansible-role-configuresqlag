Param (
    [string]$runAsUser,
    [string]$runAsPassword,
    [String]$clustername,
    [String]$primarySqlServer,
    [String]$secondarySqlServer,
    [String]$sql01ip2,
    [String]$sql02ip2,
    [String]$cquorum
)

$password = $runAsPassword | ConvertTo-SecureString -asPlainText -Force
$username = $runAsUser 
$credential = New-Object System.Management.Automation.PSCredential($username,$password)
$sysFQDN = [System.Net.Dns]::GetHostByName(($env:computerName)) | FL HostName | Out-String | %{ "{0}" -f $_.Split(':')[1].Trim() }
$session = New-PSSession -cn $sysFQDN -Credential $credential -Authentication Credssp

$ErrorActionPreference = "Stop"

Invoke-Command -ComputerName $secondarySqlServer -Credential $credential {
    Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools
}

Invoke-Command -Session $session -ScriptBlock {
    Param (
        [string]$runAsUser,
        [string]$runAsPassword,
        [String]$clustername,
        [String]$primarySqlServer,
        [String]$secondarySqlServer,
        [String]$sql01ip2,
        [String]$sql02ip2,
        [String]$cquorum
    )

    Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools
    New-Cluster -Name $clustername -Node  $primarySqlServer,$secondarySqlServer -StaticAddress $sql01ip2,$sql02ip2
    #Get-Cluster | Format-List *
    #Get-ClusterNode -Cluster $clustername | Format-List *
    $cquorum = "\\" + $cquorum
    Set-ClusterQuorum -NodeAndFileShareMajority $cquorum
} -ArgumentList @($runAsUser,$runAsPassword,$clustername,$primarySqlServer,$secondarySqlServer,$sql01ip2,$sql02ip2,$cquorum)


