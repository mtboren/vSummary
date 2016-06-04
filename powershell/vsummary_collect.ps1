#REQUIRES -Version 3.0

<#

This powershell script is under active development and is designed to be used in conjunction with:
vSummary - https://github.com/gbolo/vSummary


DESCRIPTION:
    The Function of this script is to retrieve data from vcenter;
    then send that data via http POST to a local/remote php server in JSON format.

TODO:
    - Merge get-view of same viewtype
    - Create a view into vmkernel interfaces
    - Create a view into VM Snapshots
    - Fix `#requires -PsSnapin VMware.VimAutomation.Core -Version 5` to work with 6
    - Alot more stuff I can't think of right now!

#>

function post_to_vsummary($json, $url)
{
    # maybe add gzip and auth or api key?
    try {
        $request = Invoke-WebRequest -Uri $url -Body $json -ContentType "application/json" -Method Post -ErrorAction SilentlyContinue
    }
    catch [System.Net.WebException] {
        $request = $_.Exception.Response
        return 500
    }
    catch {
        Write-Error $_.Exception
        return 500
    }
    return $request.StatusCode

}


function Hash($textToHash)
{
    $hasher = new-object System.Security.Cryptography.SHA1Managed
    $toHash = [System.Text.Encoding]::UTF8.GetBytes($textToHash)
    $hashByteArray = $hasher.ComputeHash($toHash)
    foreach($byte in $hashByteArray)
    {
         $res += $byte.ToString()
    }
    return $res;
}

## REMOVE THIS FUNCTION, since it is used nowhere in this project; but, if keeping it, it has been updated a bit to be a bit more clean
function Get-VMHostSerialNumber {
    param([VMware.VimAutomation.Types.VMHost[]]$InputObject = $null)

    process {
        ## get a bit more specific as to the property, to be a bit more efficient -- was about five (5) times faster in my testing
        $hView = $_ | Get-View -Property Hardware.SystemInfo
        ## define the properties via New-Object call (like is done in the rest of this .ps1), instead of via Add-Member; and, just get the IdentifierValue property right in the property definition, instead of creating two other, unnecessary variables in this function
        $obj = New-Object -TypeName PSObject -Property @{
            VMHost = $_
            ServiceTag = ($hView.Hardware.SystemInfo.OtherIdentifyingInfo | Where-Object {$_.IdentifierType.Key -eq "ServiceTag"}).IdentifierValue
            AssetTag = ($hView.Hardware.SystemInfo.OtherIdentifyingInfo | Where-Object {$_.IdentifierType.Key -eq "AssetTag"}).IdentifierValue
        }
        Write-Output $obj
    }
}

Function Get-vmSummary ( [string]$vc_uuid ){

    $objecttype = "VM"
    ## very precise as to what properties to grab -- good!
    &{Get-View -ViewType VirtualMachine -Property Name,
        Config.Files.VmPathName,
        Config.Hardware.NumCPU,
        Config.Hardware.MemoryMB,
        Config.GuestId,
        Config.Version,
        Config.Uuid,
        Config.instanceUuid,
        Config.changeVersion,
        Config.Template,
        Guest.ToolsVersion,
        Guest.ToolsRunningStatus,
        Guest.Hostname,
        Guest.IpAddress,
        Parent,
        ParentVApp,
        ResourcePool,
        Summary.Quickstats.OverallCpuUsage,
        Summary.Quickstats.HostMemoryUsage,
        Summary.Quickstats.GuestMemoryUsage,
        Summary.Quickstats.UptimeSeconds,
        Runtime.PowerState,
        Runtime.Host | %{
            $vm = $_
            New-Object -TypeName PSobject -Property @{
                name = $vm.Name
                ## example of having removed the ".Value" portion that was returning just half of the actual MoRef; see "observations" doc for explanation of this suggestion
                moref = $vm.MoRef
                vmx_path = $vm.Config.Files.VmPathName
                vcpu = $vm.Config.Hardware.NumCPU
                memory_mb = $vm.Config.Hardware.MemoryMB
                config_guest_os = $vm.Config.GuestId
                config_version = $vm.Config.Version
                smbios_uuid = $vm.Config.Uuid
                instance_uuid = $vm.Config.instanceUuid
                config_change_version = $vm.Config.changeVersion
                guest_tools_version = $vm.Guest.ToolsVersion
                guest_tools_running = $vm.Guest.ToolsRunningStatus
                guest_hostname = $vm.Guest.Hostname
                guest_ip = $vm.Guest.IpAddress
                stat_cpu_usage = $vm.Summary.Quickstats.OverallCpuUsage
                stat_host_memory_usage = $vm.Summary.Quickstats.HostMemoryUsage
                stat_guest_memory_usage = $vm.Summary.Quickstats.GuestMemoryUsage
                stat_uptime_sec = $vm.Summary.Quickstats.UptimeSeconds
                power_state = $vm.Runtime.PowerState
                esxi_moref = $vm.Runtime.Host
                folder_moref = $vm.Parent
                template = $vm.Config.Template
                vapp_moref = $vm.ParentVApp
                resourcepool_moref = $vm.ResourcePool
                vcenter_id = $vc_uuid
                objecttype = $objecttype
            } ## end new-object
        } ## end foreach-object
    } | convertto-JSON
}

Function Get-resourcePoolSummary ( [string]$vc_uuid ){

    $objecttype = "RES"

    &{Get-View -ViewType ResourcePool -Property Name,
        Owner,
        OverallStatus,
        Parent,
        Summary | %{
            $res = $_
            Switch ($res.GetType().Name) {
                # ResourcePool
                "ResourcePool" {
                    $type = "ResourcePool"
                    $vapp_state = "n/a"

                }
                # vApp
                "VirtualApp" {
                    $type = "VirtualApp"
                    $vapp_state = $res.Summary.VAppState
                }
            }

            New-Object -TypeName PSobject -Property @{
                name = $res.Name
                moref = $res.MoRef.Value
                type = $type
                status = $res.OverallStatus
                vapp_state = $vapp_state
                parent_moref = $res.Parent.Value
                cluster_moref = $res.Owner.Value
                configured_memory_mb = $res.Summary.ConfiguredMemoryMB
                cpu_reservation =  $res.summary.Config.CpuAllocation.Reservation
                cpu_limit = $res.summary.Config.CpuAllocation.Limit
                mem_reservation =  $res.summary.Config.MemoryAllocation.Reservation
                mem_limit = $res.summary.Config.MemoryAllocation.Limit
                vcenter_id = $vc_uuid
                objecttype = $objecttype
            } ## end new-object
        } ## end foreach-object
    } | convertto-JSON
}

Function Get-vNicSummary ( [string]$vc_uuid ){

    $objecttype = "VNIC"

    $dvs = @(Get-View -ViewType DistributedVirtualSwitch -Property Name,Uuid)

    $dvs | %{$_.UpdateViewData("Portgroup.Key","Portgroup.Name")}

    &{Get-View -ViewType VirtualMachine -Property Name,Config.Hardware.Device, Runtime.Host.Value | %{
        $vm = $_
        $vm_moref = $vm.MoRef.Value
        $esxi_moref = $vm.Runtime.Host.Value
        ## worthy of a citation?  It _is_ some strong code (like it was in 2011 at https://communities.vmware.com/message/1887826)
        ## updated a bit of View data (to be used in the LinkedView properties later -- this is faster than using multiple Get-View calls for properties that are MoRefs themselves)
        $vm.UpdateViewData("Runtime.Host.ConfigManager.NetworkSystem.NetworkInfo.Vswitch","Runtime.Host.ConfigManager.NetworkSystem.NetworkInfo.ProxySwitch","Runtime.Host.ConfigManager.NetworkSystem.NetworkInfo.PortGroup")
        $vm.Config.Hardware.Device | ?{$_ -is [VMware.Vim.VirtualEthernetCard]} | %{
            $vnic = $_
            $portgroup_name = $vswitch_type = $vswitch_name = $null

            $connected = $vnic.Connectable.Connected
            $status = $vnic.Connectable.Status

            Switch ($vnic.Backing.GetType().Name) {
                ## Standard vSwitch
                "VirtualEthernetCardNetworkBackingInfo" {
                    $portgroup_moref = "null"
                    $portgroup_name = $vnic.Backing.DeviceName
                    $pg = $vm.Runtime.LinkedView.Host.ConfigManager.LinkedView.NetworkSystem.NetworkInfo.Portgroup | ?{$_.Spec.Name -eq $vnic.Backing.DeviceName}
                    $vswitch_name = $pg.Spec.VswitchName
                    $vswitch_vm_obj = $vm.Runtime.LinkedView.Host.ConfigManager.LinkedView.NetworkSystem.NetworkInfo.Vswitch | ?{$_.Key -eq $pg.Vswitch}
                    $vswitch_type = if ($vswitch_vm_obj) {$vswitch_vm_obj.GetType().Name} else {"vSwitch type not found"}
                    break;
                }
                ## DVS Switch
                "VirtualEthernetCardDistributedVirtualPortBackingInfo" {
                    $dvs_vm_obj = $dvs | ?{$_.Uuid -eq $vnic.Backing.Port.SwitchUuid}
                    $pg = $dvs_vm_obj.LinkedView.Portgroup | ?{$_.Key -eq $vnic.Backing.Port.PortgroupKey}
                    $portgroup_moref = $pg.MoRef.Value
                    $portgroup_name = $pg.Name
                    $vswitch_name = $dvs_vm_obj.Name
                    $vswitch_type = if ($dvs_vm_obj) {$dvs_vm_obj.GetType().Name} else {"dvSwitch type not found"}
                    break;
                }
            }

            New-Object -TypeName PSobject -Property @{
                name = $_.DeviceInfo.Label
                vm_moref = $vm_moref
                esxi_moref = $esxi_moref
                type = $_.GetType().Name
                mac = $_.MacAddress
                connected = $connected
                status = $status
                portgroup_name = $portgroup_name
                portgroup_moref = $portgroup_moref
                vswitch_type = $vswitch_type
                vswitch_name = $vswitch_name
                vcenter_id = $vc_uuid
                objecttype = $objecttype
            } ## end new-object
        } ## end foreach-object
    } ## end foreach-object
    } | convertto-JSON



}

Function Get-EsxiSummary ( [string]$vc_uuid ){

    $objecttype = "ESXI"

    &{Get-View -ViewType HostSystem -Property Name,
        Parent,
        Summary.MaxEVCModeKey,
        Summary.CurrentEVCModeKey,
        Summary.OverallStatus,
        Summary.Runtime.PowerState,
        Summary.Runtime.InMaintenanceMode,
        Summary.Hardware.Vendor,
        Summary.Hardware.Model,
        Summary.Hardware.Uuid,
        Summary.Hardware.MemorySize,
        Summary.Hardware.CpuModel,
        Summary.Hardware.CpuMhz,
        Summary.Hardware.NumCpuPkgs,
        Summary.Hardware.NumCpuCores,
        Summary.Hardware.NumCpuThreads,
        Summary.Hardware.NumNics,
        Summary.Hardware.NumHBAs,
        Summary.Config.Product.Version,
        Summary.Config.Product.Build,
        Summary.Quickstats.OverallCpuUsage,
        Summary.Quickstats.OverallMemoryUsage,
        Summary.Quickstats.Uptime | %{
            $esxi = $_
            New-Object -TypeName PSobject -Property @{
                name = $esxi.Name
                moref = $esxi.MoRef.Value
                max_evc = $esxi.Summary.MaxEVCModeKey
                current_evc = $esxi.Summary.CurrentEVCModeKey
                status = $esxi.Summary.OverallStatus
                power_state = $esxi.Summary.Runtime.PowerState
                in_maintenance_mode = $esxi.Summary.Runtime.InMaintenanceMode
                vendor = $esxi.Summary.Hardware.Vendor
                model = $esxi.Summary.Hardware.Model
                uuid = $esxi.Summary.Hardware.Uuid
                memory_bytes = $esxi.Summary.Hardware.MemorySize
                cpu_model = $esxi.Summary.Hardware.CpuModel
                cpu_mhz = $esxi.Summary.Hardware.CpuMhz
                cpu_sockets = $esxi.Summary.Hardware.NumCpuPkgs
                cpu_cores = $esxi.Summary.Hardware.NumCpuCores
                cpu_threads = $esxi.Summary.Hardware.NumCpuThreads
                nics = $esxi.Summary.Hardware.NumNics
                hbas = $esxi.Summary.Hardware.NumHBAs
                version = $esxi.Summary.Config.Product.Version
                build = $esxi.Summary.Config.Product.Build
                stat_cpu_usage = $esxi.Summary.Quickstats.OverallCpuUsage
                stat_memory_usage = $esxi.Summary.Quickstats.OverallMemoryUsage
                stat_uptime_sec = $esxi.Summary.Quickstats.Uptime
                cluster_moref = $esxi.Parent.Value
                vcenter_id = $vc_uuid
                objecttype = $objecttype
            } ## end new-object
        } ## end foreach-object
    } | convertto-JSON
}

Function Get-pNicSummary ( [string]$vc_uuid ){

    $objecttype = "PNIC"

    &{Get-View -ViewType HostSystem -Property Name,
        Config.Network.Pnic | %{
            $esxi = $_
            $esxi.Config.Network.Pnic | %{
                $pnic = $_
                New-Object -TypeName PSobject -Property @{
                    name = $pnic.Device
                    mac = $pnic.Mac
                    driver = $pnic.Driver
                    link_speed = $pnic.LinkSpeed.SpeedMB
                    esxi_moref = $esxi.MoRef.Value
                    vcenter_id = $vc_uuid
                    objecttype = $objecttype
                } ## end new-object
            } ## end foreach-object
        } ## end foreach-object
    } | convertto-JSON
}


Function Get-svsSummary ( [string]$vc_uuid ){

    $objecttype = "SVS"

    &{Get-View -ViewType HostSystem -Property Name,
        Config.Network.Vswitch | %{
            $esxi = $_
            $esxi.Config.Network.Vswitch | %{
                $vswitch = $_
                New-Object -TypeName PSobject -Property @{
                    name = $vswitch.Name
                    ports = $vswitch.Spec.NumPorts
                    max_mtu = $vswitch.Mtu
                    esxi_moref = $esxi.MoRef.Value
                    vcenter_id = $vc_uuid
                    objecttype = $objecttype
                } ## end new-object
            } ## end foreach-object
        } ## end foreach-object
    } | convertto-JSON
}

Function Get-clusterSummary ( [string]$vc_uuid ){

    $objecttype = "CLUSTER"

    &{Get-View -ViewType ClusterComputeResource -Property Name,
        OverallStatus,
        Parent,
        Configuration.DasConfig,
        Configuration.DrsConfig,
        Summary | %{
            $cluster = $_
            New-Object -TypeName PSobject -Property @{
                name = $cluster.Name
                moref = $cluster.MoRef.Value
                datacenter_moref = $cluster.Parent.Value
                total_cpu_threads = $cluster.Summary.NumCpuThreads
                total_cpu_mhz = $cluster.Summary.TotalCpu
                total_memory_bytes = $cluster.Summary.TotalMemory
                total_vmotions = $cluster.Summary.NumVmotions
                num_hosts = $cluster.Summary.NumHosts
                current_balance = $cluster.Summary.CurrentBalance
                target_balance = $cluster.Summary.TargetBalance
                drs_enabled = [string]$cluster.Configuration.DrsConfig.Enabled
                drs_behaviour = $cluster.Configuration.DrsConfig.DefaultVmBehavior
                ha_enabled = [string]$cluster.Configuration.DasConfig.Enabled
                status = [string]$cluster.OverallStatus
                vcenter_id = $vc_uuid
                objecttype = $objecttype
            } ## end new-object
        } ## end foreach-object
    } | convertto-JSON
}

Function Get-dvsSummary ( [string]$vc_uuid ){

    $objecttype = "DVS"

    &{Get-View -ViewType DistributedVirtualSwitch -Property Name,
        Summary.ProductInfo.Version,
        Config | %{
            $dvs = $_
            New-Object -TypeName PSobject -Property @{
                name = $dvs.Name
                moref = $dvs.MoRef.Value
                version = $dvs.Summary.ProductInfo.Version
                max_mtu = $dvs.Config.MaxMtu
                ports = $dvs.Config.NumPorts
                vcenter_id = $vc_uuid
                objecttype = $objecttype
            } ## end new-object
        } ## end foreach-object
    } | convertto-JSON
}

Function Get-dcSummary ( [string]$vc_uuid ){

    $objecttype = "DC"

    &{Get-View -ViewType Datacenter -Property Name,
        HostFolder,
        VmFolder | %{
            $dc = $_
            New-Object -TypeName PSobject -Property @{
                name = $dc.Name
                moref = $dc.MoRef.Value
                vm_folder_moref = $dc.VmFolder.Value
                esxi_folder_moref = $dc.HostFolder.Value
                vcenter_id = $vc_uuid
                objecttype = $objecttype
            } ## end new-object
        } ## end foreach-object
    } | convertto-JSON
}


Function Get-folderSummary ( [string]$vc_uuid ){

    $objecttype = "FOLDER"

    &{Get-View -ViewType Folder -Property Name,
        Parent,
        ChildType | %{
            $folder = $_
            New-Object -TypeName PSobject -Property @{
                name = $folder.Name
                moref = $folder.MoRef.Value
                type = [string]$folder.ChildType
                parent_moref = $folder.Parent.Value
                vcenter_id = $vc_uuid
                objecttype = $objecttype
            } ## end new-object
        } ## end foreach-object
    } | convertto-JSON
}


Function Get-dvsPgSummary ( [string]$vc_uuid ){

    $objecttype = "DVSPG"

    &{Get-View -ViewType DistributedVirtualPortgroup -Property Name,
        Config.DefaultPortConfig,
        Config.DistributedVirtualSwitch | %{
            $pg = $_
            $vlan_type = $pg.Config.DefaultPortConfig.Vlan.GetType().Name

            # single vlan id
            if ( $vlan_type -eq "VmwareDistributedVirtualSwitchVlanIdSpec" ) {
                $vlan = $pg.Config.DefaultPortConfig.Vlan.VlanId
                $vlan_start = "na"
                $vlan_end = "na"
            } ElseIf ( $vlan_type -eq "VmwareDistributedVirtualSwitchTrunkVlanSpec" ) {
                $vlan = "na"
                $vlan_start = [string]$pg.Config.DefaultPortConfig.Vlan.VlanId.Start
                $vlan_end = [string]$pg.Config.DefaultPortConfig.Vlan.VlanId.End
            } Else {
                $vlan = "TypeNotImplemented"
                $vlan_start = "na"
                $vlan_end = "na"
            }
            #SUPPORT IS NEEDED FOR VLAN TRUNKING AND OTHER TYPES
            # VmwareDistributedVirtualSwitchTrunkVlanSpec
            # $DVPG.Config.DefaultPortConfig.Vlan.VlanId.Start
            # $DVPG.Config.DefaultPortConfig.Vlan.VlanId.End
            New-Object -TypeName PSobject -Property @{
                name = $pg.Name
                moref = $pg.MoRef.Value
                vlan_type  = $vlan_type
                vlan = $vlan
                vlan_start = $vlan_start
                vlan_end = $vlan_end
                dvs_moref = $pg.Config.DistributedVirtualSwitch.Value
                vcenter_id = $vc_uuid
                objecttype = $objecttype
            } ## end new-object
        } ## end foreach-object
    } | convertto-JSON
}

Function Get-svsPgSummary ( [string]$vc_uuid ){

    $objecttype = "SVSPG"

    &{Get-View -ViewType HostSystem -Property Name,
        Config.Network.Portgroup | %{
            $esxi = $_
            $esxi.Config.Network.Portgroup.Spec | %{
                $pg = $_
                New-Object -TypeName PSobject -Property @{
                    name = $pg.Name
                    vswitch_name = $pg.VswitchName
                    vlan = $pg.VlanId
                    esxi_moref = $esxi.MoRef.Value
                    vcenter_id = $vc_uuid
                    objecttype = $objecttype
                } ## end new-object
            } ## end foreach-object
        } ## end foreach-object
    } | convertto-JSON
}


Function Get-datastoreSummary ( [string]$vc_uuid ){

    $objecttype = "DS"

    &{Get-View -ViewType Datastore -Property Name,
            OverallStatus,
            Summary.Capacity,
            Summary.FreeSpace,
            Summary.Type,
            Summary.Uncommitted | %{
            $ds = $_
            New-Object -TypeName PSobject -Property @{
                name = $ds.Name
                moref = $ds.MoRef.Value
                status = $ds.OverallStatus
                capacity_bytes = $ds.Summary.Capacity
                free_bytes = $ds.Summary.FreeSpace
                uncommitted_bytes = $ds.Summary.Uncommitted
                type = $ds.Summary.Type
                vcenter_id = $vc_uuid
                objecttype = $objecttype
            } ## end new-object
        } ## end foreach-object
    } |  convertto-JSON
}



Function Get-vDiskSummary ( [string]$vc_uuid ){

    $objecttype = "VDISK"

    &{Get-View -ViewType VirtualMachine -Property Name,
        Config.Hardware.Device,
        Config.instanceUuid,
        Runtime.Host | %{
            $vm = $_
            $vm.Config.Hardware.Device | ?{$_ -is [VMware.Vim.VirtualDisk]} | %{
                $vdisk = $_

                ## Collect both capacity_bytes and capacityInKB since vm version vmx-07 and lower will not have capacity_bytes
                ## https://www.vmware.com/support/developer/converter-sdk/conv55_apireference/vim.vm.device.VirtualDisk.html
                New-Object -TypeName PSobject -Property @{
                    name = $vdisk.DeviceInfo.Label
                    capacity_bytes = $vdisk.CapacityInBytes
                    capacity_kb = $vdisk.capacityInKB
                    path = $vdisk.Backing.Filename
                    thin_provisioned = $vdisk.Backing.ThinProvisioned
                    datastore_moref = $vdisk.Backing.Datastore.Value
                    uuid = $vdisk.Backing.uuid
                    disk_object_id = $vdisk.diskObjectId
                    vm_moref = $vm.MoRef.Value
                    esxi_moref = $vm.Runtime.Host.Value
                    vcenter_id = $vc_uuid
                    objecttype = $objecttype
                } ## end new-object
            } ## end foreach-object
        } ## end foreach-object
    } | convertto-JSON
}

function vsummary_checks( [string]$vc_uuid, [string]$url ){
    ## great opportunity to be efficient by leveraging a data structure and iteration, instead of typing or copying/pasting what are essentially the same two lines over and over and over (14 times over)
    ## say, like:
    # $hshChecksToRun = @{
    #     esxi = "Get-EsxiSummary"
    #     pnic = "Get-pNicSummary"
    #     datastore = "Get-datastoreSummary"
    # }
    # ## Run Checks
    # $hshChecksToRun.Keys | Foreach-Object {
    #     $strThisCheckTopic = $_
    #     $strFunctionToInvoke = $hshChecksToRun[$strThisCheckTopic]
    #     $status = post_to_vsummary (& $strFunctionToInvoke $vc_uuid) $url
    #     Write-Verbose -Verbose "$strThisCheckTopic check http status code: $status"
    # }


    # Run Checks
    $status = post_to_vsummary (Get-EsxiSummary $vc_uuid) $url
    Write-Host "esxi check http status code: $status"
    $status = post_to_vsummary (Get-pNicSummary $vc_uuid) $url
    Write-Host "pnic check http status code: $status"
    $status = post_to_vsummary (Get-datastoreSummary $vc_uuid) $url
    Write-Host "datastore check http status code: $status"
    $status = post_to_vsummary (Get-vmSummary $vc_uuid) $url
    Write-Host "vm check http status code: $status"
    $status = post_to_vsummary (Get-svsSummary $vc_uuid) $url
    Write-Host "vswitch check http status code: $status"
    $status = post_to_vsummary (Get-dvsSummary $vc_uuid) $url
    Write-Host "dvs check http status code: $status"
    $status = post_to_vsummary (Get-svsPgSummary $vc_uuid) $url
    Write-Host "vswitch_pg check http status code: $status"
    $status = post_to_vsummary (Get-dvsPgSummary $vc_uuid) $url
    Write-Host "dvs_pg check http status code: $status"
    $status = post_to_vsummary (Get-vNicSummary $vc_uuid) $url
    Write-Host "vnic check http status code: $status"
    $status = post_to_vsummary (Get-vDiskSummary $vc_uuid) $url
    Write-Host "vdisk check http status code: $status"
    $status = post_to_vsummary (Get-resourcePoolSummary $vc_uuid) $url
    Write-Host "resourcepool check http status code: $status"
    $status = post_to_vsummary (Get-dcSummary $vc_uuid) $url
    Write-Host "datacenter check http status code: $status"
    # Folder check needs to be done after datacenter check
    $status = post_to_vsummary (Get-folderSummary $vc_uuid) $url
    Write-Host "folder check http status code: $status"
    $status = post_to_vsummary (Get-clusterSummary $vc_uuid) $url
    Write-Host "Cluster check http status code: $status"
}


# ADD YOUR vSUMMARY PHP ENDPOINT HERE:
$vsummary_url = 'http://vsummary.linuxctl.com/api/update.php'

# ADD YOUR VCENTER SERVERS LIKE THIS:
$vcenters = @{
    LAB = @{ fqdn = 'vcsa1.lab.linuxctl.com'; readonly_user = 'readonly@vsphere.local'; password = 'changeme'; };
    VDI = @{ fqdn = 'vcsa1.vdi.linuxctl.com'; readonly_user = 'ro@vsphere.local'; password = 'changeme'; };
    PROD = @{ fqdn = 'vcsa1.prod.linuxctl.com'; readonly_user = 'ro@vsphere.local'; password = 'changeme'; };
    DR = @{ fqdn = 'vcsa1.dr.linuxctl.com'; readonly_user = 'ro@vsphere.local'; password = 'changeme'; };
}

foreach($vc in $vcenters.Keys)
{
    $vc_shortname = $vc
    $vc_fqdn = $vcenters.Item($vc).fqdn
    $vc_user = $vcenters.Item($vc).readonly_user
    $vc_pass = $vcenters.Item($vc).password

    if ($global:DefaultVIServers.Count -gt 0) {
        Disconnect-VIServer -Server * -Force -Confirm:$false -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Out-Null
    }

    $c = Connect-VIServer $vc_fqdn -user $vc_user -password $vc_pass

    if ($c){
        $vc_uuid = $c.InstanceUuid
        Write-Host "============================"
        Write-Host "Connected to $vc_fqdn"
        Write-Host "============================"

        $vc_obj = New-Object -TypeName PSobject -Property @{
            vc_shortname = $vc_shortname
            vc_uuid = $vc_uuid
            vc_fqdn = $vc_fqdn
            objecttype = 'VCENTER'
        }
        $json = $vc_obj | ConvertTo-JSON

        # SEND VCENTER INFO
        $status = post_to_vsummary $json $vsummary_url
        Write-Host "vcenter check http status code: $status"

        # SEND ALL CHECKS
        vsummary_checks $vc_uuid $vsummary_url

    } Else {
        Write-Host "Could not connect to $vc_fqdn"
    }

}

if ($global:DefaultVIServers.Count -gt 0) {
    Disconnect-VIServer -Server * -Force -Confirm:$false
}