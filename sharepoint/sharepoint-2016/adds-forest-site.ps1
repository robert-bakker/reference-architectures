# $AdminCreds            -  a PSCredentials object that contains username and password 
#                           that will be assigned to the Domain Administrator account
# $SafeModeAdminCreds    -  a PSCredentials object that contains the password that will
#                           be assigned to the Safe Mode Administrator account
# $DomainName            -  FQDN for the Active Directory Domain to create
# $DomainNetbiosName     -  Netbios name for the Active Directory Domain to create
# $SiteName              -  Name of the Active Directory replicationm site
# $OnpremSiteName        -  Name of the Active Directory replication site to link to
# $Cidr                  -  Subnet for the Active Directory replication
# $ReplicationFrequency  -  Frequency of the replication
# $TargetDomainName      -  Domain Name to establish the Trust
# $ForwardIpAddress      -  IP Addresses used for set the conditional forward zone
#                           for the trust relationship
# $RetryCount            -  defines how many retries should be performed while waiting
#                           for the domain to be provisioned
# $RetryIntervalSec      -  defines the seconds between each retry to check if the 
#                           domain has been provisioned 
Configuration CreateForest {
    param
    (
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$AdminCreds,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$SafeModeAdminCreds,

        [Parameter(Mandatory)]
        [string]$DomainName,

        [Parameter(Mandatory)]
        [string]$DomainNetbiosName,

        [Parameter(Mandatory)]
        [string]$SiteName,

        [Parameter(Mandatory=$True)]
        [string]$OnpremSiteName,
      
        [Parameter(Mandatory=$True)]
        [string]$Cidr,
      
        [Parameter(Mandatory=$True)]
        [int]$ReplicationFrequency,        
        
        [Parameter(Mandatory)]
        [string]$TargetDomainName,
        
        [Parameter(Mandatory)]
        [string]$ForwardIpAddress,

        [Int]$RetryCount=20,
        [Int]$RetryIntervalSec=30
    )

    Import-DscResource -ModuleName xStorage, xActiveDirectory, xNetworking, xPendingReboot

    [System.Management.Automation.PSCredential ]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($AdminCreds.UserName)", $AdminCreds.Password)
    [System.Management.Automation.PSCredential ]$SafeDomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($SafeModeAdminCreds.UserName)", $SafeModeAdminCreds.Password)

    $Interface = Get-NetAdapter|Where-Object Name -Like "Ethernet*"|Select-Object -First 1
    $InterfaceAlias = $($Interface.Name)
    
    Node localhost
    {
        LocalConfigurationManager
        {            
            ActionAfterReboot = 'ContinueConfiguration'            
            ConfigurationMode = 'ApplyOnly'            
            RebootNodeIfNeeded = $true            
        } 

        xWaitforDisk Disk2
        {
            DiskId = 2
            RetryIntervalSec = 60
            RetryCount = 20
        }
        
        xDisk FVolume
        {
            DiskId = 2
            DriveLetter = 'F'
            FSLabel = 'Data'
            FSFormat = 'NTFS'
            DependsOn = '[xWaitForDisk]Disk2'
        }        

        WindowsFeature DNS 
        { 
            Ensure = "Present" 
            Name = "DNS"
            IncludeAllSubFeature = $true
        }

        WindowsFeature RSAT
        {
             Ensure = "Present"
             Name = "RSAT"
             IncludeAllSubFeature = $true
        }

        WindowsFeature ADDSInstall 
        { 
            Ensure = "Present" 
            Name = "AD-Domain-Services"
            IncludeAllSubFeature = $true
        }  

        xDnsServerAddress DnsServerAddress 
        { 
            Address        = '127.0.0.1' 
            InterfaceAlias = $InterfaceAlias
            AddressFamily  = 'IPv4'
            DependsOn = "[WindowsFeature]DNS"
        }

        xADDomain AddDomain
        {
            DomainName = $DomainName
            DomainNetbiosName = $DomainNetbiosName
            DomainAdministratorCredential = $DomainCreds
            SafemodeAdministratorPassword = $SafeDomainCreds
            DatabasePath = "F:\Adds\NTDS"
            LogPath = "F:\Adds\NTDS"
            SysvolPath = "F:\Adds\SYSVOL"
            DependsOn = "[xWaitForDisk]Disk2","[WindowsFeature]ADDSInstall","[xDnsServerAddress]DnsServerAddress"
        }

        xWaitForADDomain DomainWait
        {
            DomainName = $DomainName
            DomainUserCredential = $DomainCreds
            RetryCount = $RetryCount
            RetryIntervalSec = $RetryIntervalSec
            RebootRetryCount = 5
            DependsOn = "[xADDomain]AddDomain"
        } 

        xADDomainController PrimaryDC 
        {
            DomainName = $DomainName
            DomainAdministratorCredential = $DomainCreds
            SafemodeAdministratorPassword = $SafeDomainCreds
            DatabasePath = "F:\Adds\NTDS"
            LogPath = "F:\Adds\NTDS"
            SysvolPath = "F:\Adds\SYSVOL"
            DependsOn = "[xWaitForADDomain]DomainWait"
        }

        Script SetReplication
        {
            GetScript = {
                $getFilter = {Name -like "$using:SiteName"}
                $replicationSite = Get-ADReplicationSite -Filter $getFilter
                return @{ 'Result' = $replicationSite.Name }
            }
            TestScript = {
                $testFilter = {Name -like "$using:SiteName"}
                If (Get-ADReplicationSite -Filter $testFilter)
                {
                    If (Get-ADReplicationSubnet -Filter *) 
                    {
                        return $true
                    }
                }
                Write-Verbose -Message ('ReplicationSite or ReplicationSubnet not installed')
                
                return $false
            }
            SetScript = { 
                
                $Description="azure vnet ad site"
                $Location="azure subnet location"
                $SitelinkName = "AzureToOnpremLink"

                Write-Verbose -Message ('Installing ReplicationSite')
                New-ADReplicationSite -Name $using:SiteName -Description $Description # -Credential $DomainCreds 

                Write-Verbose -Message ('Installing ReplicationSubnet')
                New-ADReplicationSubnet -Name $using:Cidr -Site $using:SiteName -Location $Location # -Credential $DomainCreds 
                
                Write-Verbose -Message ('Installing ReplicationSiteLink')
                New-ADReplicationSiteLink -Name $SitelinkName -SitesIncluded $using:OnpremSiteName, $using:SiteName -Cost 100 -ReplicationFrequency $using:ReplicationFrequency -InterSiteTransportProtocol IP #-Credential $DomainCreds
            }
            DependsOn = "[xWaitForADDomain]DomainWait"
        }

        Script SetConditionalForwardedZone {
            GetScript = {return @{}}

            TestScript = {
                $zone = Get-DnsServerZone -Name $using:TargetDomainName -ErrorAction SilentlyContinue
                if($zone -ne $null -and $zone.ZoneType -eq 'Forwarder'){
                    return $true
                }

                return $false
            }

            SetScript = {
                $ForwardDomainName = $using:TargetDomainName
                $ForwardAddress = $using:ForwardIpAddress
                $IpAddresses = @()
                foreach($address in $ForwardAddress.Split(',')){
                    $IpAddresses += [IPAddress]$address.Trim()
                }
                Add-DnsServerConditionalForwarderZone -Name "$ForwardDomainName" -ReplicationScope "Domain" -MasterServers $IpAddresses
            }
        }
        
        xPendingReboot Reboot1
        { 
            Name = "RebootServer"
            DependsOn = @("[Script]SetReplication")
        }
   }
}