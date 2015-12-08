Param (
    [string] $runAsUser,
    [string] $runAsPassword,
    [string] $AgListener,
    [string] $SqlServerName
)

$password = $runAsPassword | ConvertTo-SecureString -asPlainText -Force
$username = $runAsUser 
$credential = New-Object System.Management.Automation.PSCredential($username,$password)

Invoke-Command -ComputerName $SqlServerName -Credential $credential {

    Param (
        [string] $runAsUser,
        [string] $runAsPassword,
        [string] $AgListener
    )

    $wmiName = (Get-WmiObject -namespace root\Microsoft\SqlServer\ReportServer  -class __Namespace).Name
    $rsConfig = Get-WmiObject -namespace "root\Microsoft\SqlServer\ReportServer\$wmiName\v11\Admin" -class MSReportServer_ConfigurationSetting -filter "InstanceName='MSSQLSERVER'"
    $rsConfig.SetDatabaseConnection($AgListener, "ReportServer", 0, $runAsUser, $runAsPassword)
    $rsConfig.SetServiceState($false,$false,$false)
    $rsConfig.SetServiceState($true,$true,$true)

} -ArgumentList @($runAsUser,$runAsPassword,$AgListener)
