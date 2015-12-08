######
## Note variable IP1 and IP2 should be in form num/subnet, ie, '10.71.1.35/255.255.252.0'
Param (
    [string] $dnetBIOS,
    [string] $runAsUser,
    [string] $runAsPassword,
    [string] $AgName,
    [string] $AgListener,
    [string] $SqlServerName,
    [string] $IP1,
    [string] $IP2
)

$password = $runAsPassword | ConvertTo-SecureString -asPlainText -Force
$username = $runAsUser 
$credential = New-Object System.Management.Automation.PSCredential($username,$password)
$session = New-PSSession -Credential $credential

$sqlperms = @"
use [master];
GRANT ALTER ANY AVAILABILITY GROUP TO [$dnetBIOS\sqlservice];
GRANT CONNECT SQL TO [$dnetBIOS\sqlservice];
GRANT VIEW SERVER STATE TO [$dnetBIOS\sqlservice];
"@

Invoke-Command -Session $session -ScriptBlock {

    Param (
        [string] $dnetBIOS,
        [string] $runAsUser,
        [string] $runAsPassword,
        [string] $AgName,
        [string] $AgListener,
        [string] $SqlServerName,
        [string] $IP1,
        [string] $IP2,
        [string] $sqlperms
    )

    Import-Module SQLPS -DisableNameChecking

    $password = $runAsPassword | ConvertTo-SecureString -asPlainText -Force
    $username = $runAsUser 
    $credential = New-Object System.Management.Automation.PSCredential($username,$password)

    $replicas = @()

    $cname = (Get-Cluster | Where-Object{$_.Name -match "$SqlServerName"}).Name
    $nodes = (Get-ClusterNode | Where-Object{$_.Cluster -match "$cname"}).Name

    foreach($node in $nodes){
        Invoke-Command -ComputerName $node -Credential $credential {
            Param(
                [string]$node,
                [string]$sqlperms
            )

            [System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.SMO') | out-null

            $srv = new-object ('Microsoft.SqlServer.Management.Smo.Server') $node
            if($srv.IsHadrEnabled -eq $false){
                Enable-SqlAlwaysOn -Path "SQLSERVER:\SQL\$node\DEFAULT" -Force
                [System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.SqlWmiManagement') | out-null
                $mc = new-object ('Microsoft.SqlServer.Management.Smo.Wmi.ManagedComputer') $node
                $sqlsrvc = $mc.Services["MSSQLSERVER"]                 
                Write-Host "Stopping MSSQLSERVER"                 
                $sqlsrvc.Stop()
                start-sleep -s 20
                $sqlsrvc.Start()                 
                Write-Host "Started MSSQLSERVER"
                $sqlagnt = $mc.Services["SQLSERVERAGENT"]                 
                Write-Host "Stopping SQL Server Agent"                 
                $sqlagnt.Stop()
                start-sleep -s 20
                $sqlagnt.Start()                 
                Write-Host "Started SQL Server Agent"
            }
            else{
                Write-Host "AlwayaOn is already enabled on "$node
            }
            Invoke-Sqlcmd -HostName $node -Database master -Query $sqlperms
            $endpointQuery = "Select name, state_desc, port from sys.tcp_endpoints where type_desc='DATABASE_MIRRORING'"
            $endpoint = Invoke-Sqlcmd -HostName $node -Database master -Query $endpointQuery
            if($endpoint -eq $null){
                $endpoint = New-SqlHADREndpoint -Name $node -Path "SQLSERVER:\SQL\$node\DEFAULT"
                Set-SqlHadrEndpoint -InputObject $endpoint -State "Started"
            }
            else{
                if($endpoint.name -ne $node){
                    $dropQuery = "Drop ENDPOINT $endpoint.name"
                    Invoke-Sqlcmd -HostName $node -Database master -Query $dropQuery
                    $endpoint = New-SqlHADREndpoint -Name $node -Path "SQLSERVER:\SQL\$node\DEFAULT"
                    Set-SqlHadrEndpoint -InputObject $endpoint -State "Started"
                }
                Write-Host "Endpoint " $endpoint.name " Already Exists"
            }
        } -ArgumentList @($node,$sqlperms)

        $endpointURL = "TCP://" + $node + ":5022"
        $replicas += New-SqlAvailabilityReplica -Name $node -EndpointUrl $endpointURL -AvailabilityMode 'SynchronousCommit' -FailoverMode 'Automatic' -AsTemplate -Version 12
    }

    [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.SMO") | out-null
    $srv = new-object ('Microsoft.SqlServer.Management.Smo.Server') $SqlServerName
    $presentAvailabilityGroups = $srv.AvailabilityGroups | Select-object -ExpandProperty Name
    if(-not($presentAvailabilityGroups -contains $AgName)){
        New-SqlAvailabilityGroup -Name $AgName -Path "SQLSERVER:\SQL\$SqlServerName\DEFAULT" -AvailabilityReplica $replicas
    }
    else{
        Write-Host "Availability Group" $AGName " Already Present on "$SqlServerName
    }

    foreach($node in $nodes){
        if($node -ne $SqlServerName){
            Invoke-Command -ComputerName $node -Credential $credential {
                Param(
                    [string]$node,
                    [string]$AgName
                )
                [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.SMO") | out-null
                $srv = new-object ('Microsoft.SqlServer.Management.Smo.Server') $node
                $presentAvailabilityGroups = $srv.AvailabilityGroups | Select-object -ExpandProperty Name
                if(-not($presentAvailabilityGroups -contains $AgName)){
                    Join-SqlAvailabilityGroup -path "SQLSERVER:\SQL\$node\DEFAULT" -Name $AgName
                }
                else{
                    Write-Host "Availability Group" $AGName " Already Present on "$node
                }
            } -ArgumentList @($node,$AgName)
        }
    }
    
    $srv = new-object ('Microsoft.SqlServer.Management.Smo.Server') $SqlServerName
    $primaryReplica = $srv.AvailabilityGroups["$AGName"].PrimaryReplicaServerName
    $lquery = "Select dns_name from sys.availability_group_listeners"
    $presentAvailabilityGroupListeners = Invoke-Sqlcmd -HostName $primaryReplica -Database master -Query $lquery | Select-Object -ExpandProperty dns_name
    if(-not($presentAvailabilityGroupListeners -contains $AgListener)){
        Invoke-Command -ComputerName $primaryReplica -Credential $credential {
            Param(
                [string]$node,
                [string]$AgName,
                [string]$AgListener,
                [string]$IP1,            
                [string]$IP2
            )
            New-SqlAvailabilityGroupListener -Name $AgListener -staticIP $IP1,$IP2 -Port 1433 -Path "SQLSERVER:\Sql\$node\DEFAULT\AvailabilityGroups\$AgName"
        } -ArgumentList @($primaryReplica,$AgName,$AgListener,$IP1,$IP2)
    }
    else{
        Write-Host "Availability Group Listener" $AgListener " already exists"
    }

} -ArgumentList @($dnetBIOS,$runAsUser,$runAsPassword,$AgName,$AgListener,$SqlServerName,$IP1,$IP2,$sqlperms)


