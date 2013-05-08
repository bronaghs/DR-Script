# --------------------------------------------------------------------------------------------------
# inventory-import.ps1
# This script imports the Folder/Datacenter hierarchy from the specified xml file into the current VC, # including the permissions defined in each folder or datacenter.
#
# name:		inventory-import.ps1
# args:		inputFile [optional], invRoot [optional]
# how to run:	from an existing session to a VC
#			PS C:\Scripts> .\inventory-import.ps1
#---------------------------------------------------------------------------------------------------


param($inputFile="inventory.xml")
param($invRoot="/")
$authMgr = get-view AuthorizationManager
$indxMgr = Get-View SearchIndex
$serviceInstance = get-view ServiceInstance
$rootFolder = get-view -property Name $serviceInstance.Content.rootFolder

$roleHash = @{};
$authMgr.RoleList | foreach {$roleHash[$_.name]=$_.roleId}

$xmlDoc = New-Object System.Xml.XmlDocument
$currentPath = Resolve-Path .
$xmlDoc.Load($currentPath.Path + "\" + $inputFile)
$itemList = $xmlDoc.SelectNodes("//itemList/item")
foreach($item in $itemList) {

	$name = $item.name
	$type = $item.type
	$path = $item.path		# this is the path to the parent inventory object
	$childType = $item.childType
	$currentObj = $null

	# if we have the  datacenters folder object we do not need a parent. We just get the object.
	# For all other inventory objects we find the parent and great the node off of it.
	if ($name -ne "Datacenters") {
		$parent = $indxMgr.FindByInventoryPath($path)
		if ($parent -ne $null) {
			Write-Host "parent " $parent.Value " - type " $parent.Type " already exists" 
		}
		else{
			Write-Host "Parent not found... on to next inventory object"
			continue;
		}
		
		$selfpath = $path + "/" + $item.Name
		$self = $null
		$self = $indxMgr.FindByInventoryPath($selfpath)
		trap {
			Write-Host "Error: " $_  -ForegroundColor Red;
			continue;
		}
		if ($self -ne $null) {
			$currentObj = $self
		}
		else {
			# We must have already created the parent object first so we know which parent node to create an 
			# object on.

			$pObj = Get-View -Property Name $parent
			
			if ($type -eq "Datacenter") {
				$currentObj = $pObj.CreateDatacenter($name)
			}
			elseif ($type -eq "Folder") {
				$currentObj = $pObj.CreateFolder($name)
			}
			elseif ($type -eq "HostSystem" -or $type -eq "ComputeResource"){
				Write-Host "name: " $name " parent : " $parent.Value
			}
			elseif ($type -eq "ClusterComputeResource"){
				$spec = ImportClusterConfig $item $parent $name
				$currentObj = $pObj.CreateClusterEx($name, $spec )	
			}	
			elseif ($type -eq "ResourcePool"){
				$rpSpec = ImportRPConfig $item
				$currentObj = $pObj.CreateResourcePool($name, $rpSpec)
			}
			else {
				Write-Host "unable to determine object type"
			}
		}
	}
	else {
		# if we have the Datacenters folder object we do not need to find its parent because it is the root of the tree. We just get the object.
		$currentObj = $rootFolder.MoRef
	}
	
	# Get the permissions for this managed object. This is a list of actions 
	# that can be performed by a user or group eg create a new VM

	$permissionList = @()
	foreach ($permission in $item.SelectNodes(".//permissions/permission")) {
		$role = $permission.role
		$principal = $permission.principal
		$propagate = $permission.propagate
		$group = $permission.group
		
		$perm = New-Object VMware.Vim.Permission
		if($group -eq "True") {$perm.Group=$True} else {$perm.Group=$False}
		$perm.Principal = $principal
		if($propagate -eq "True") {$perm.Propagate=$True} else {$perm.Propagate=$False}
		$perm.RoleId = $roleHash[$role]
		
		$permissionList += $perm;
	}
	#Update the authorization manager.

	$authMgr.SetEntityPermissions($currentObj,$permissionList)
}

function ImportRPConfig($item)
{
	foreach ($rpConfig in $item.SelectNodes(".//RPSettings/config")) 
	{
		$rpSpec = New-Object Vmware.Vim.ResourceConfigSpec
		$rpSpec.changeVersion = $rpConfig.changeVersion
		if ($rpConfig.lastModified)
		{
			$rpSpec.lastModified = $rpConfig.lastModified
		}
		$rpSpec.memoryAllocation = New-Object Vmware.Vim.ResourceAllocationInfo
		$rpSpec.memoryAllocation.expandableReservation = $rpConfig.selectSingleNode("memoryAllocation").selectSingleNode("expandableReservation").get_InnerXML()
		$rpSpec.memoryAllocation.overheadLimit = $rpConfig.selectSingleNode("memoryAllocation").selectSingleNode("overheadLimit").get_InnerXML()
		$rpSpec.memoryAllocation.limit = $rpConfig.selectSingleNode("memoryAllocation").selectSingleNode("limit").get_InnerXML()
		$rpSpec.memoryAllocation.reservation = $rpConfig.selectSingleNode("memoryAllocation").selectSingleNode("reservation").get_InnerXML()
		$rpSpec.memoryAllocation.shares = New-Object Vmware.Vim.SharesInfo 
		$rpSpec.memoryAllocation.shares.level = $rpConfig.selectSingleNode("memoryAllocation").selectSingleNode("shares").selectSingleNode("level").get_InnerXML()
		$rpSpec.memoryAllocation.shares.shares = $rpConfig.selectSingleNode("memoryAllocation").selectSingleNode("shares").selectSingleNode("shares").get_InnerXML()
	
		Write-Host "$rpSpec.memoryAllocation.shares.level" $rpSpec.memoryAllocation.shares.level
		Write-Host "$rpSpec.memoryAllocation.shares.shares" $rpSpec.memoryAllocation.shares.shares
		Write-Host "$rpSpec.memoryAllocation.reservation" $rpSpec.memoryAllocation.reservation
		Write-Host "$rpSpec.memoryAllocation.limit" $rpSpec.memoryAllocation.limit
		Write-Host "$rpSpec.memoryAllocation.overheadLimit" $rpSpec.memoryAllocation.overheadLimit
		Write-Host "$rpSpec.memoryAllocation.expandableReservation" $rpSpec.memoryAllocation.expandableReservation
	
		$rpSpec.cpuAllocation = New-Object Vmware.Vim.ResourceAllocationInfo
		$rpSpec.cpuAllocation.expandableReservation = $rpConfig.selectSingleNode("cpuAllocation").selectSingleNode("expandableReservation").get_InnerXML()
		$rpSpec.cpuAllocation.overheadLimit = $rpConfig.selectSingleNode("cpuAllocation").selectSingleNode("overheadLimit").get_InnerXML()
		$rpSpec.cpuAllocation.limit = $rpConfig.selectSingleNode("cpuAllocation").selectSingleNode("limit").get_InnerXML()
		$rpSpec.cpuAllocation.reservation = $rpConfig.selectSingleNode("cpuAllocation").selectSingleNode("reservation").get_InnerXML()
		$rpSpec.cpuAllocation.shares = New-Object Vmware.Vim.SharesInfo 
		$rpSpec.cpuAllocation.shares.level = $rpConfig.selectSingleNode("cpuAllocation").selectSingleNode("shares").selectSingleNode("level").get_InnerXML()
		$rpSpec.cpuAllocation.shares.shares = $rpConfig.selectSingleNode("cpuAllocation").selectSingleNode("shares").selectSingleNode("shares").get_InnerXML()
	
		Write-Host "$rpSpec.cpuAllocation.shares.level" $rpSpec.cpuAllocation.shares.level
		Write-Host "$rpSpec.cpuAllocation.shares.shares" $rpSpec.cpuAllocation.shares.shares
		Write-Host "$rpSpec.cpuAllocation.reservation" $rpSpec.cpuAllocation.reservation
		Write-Host "$rpSpec.cpuAllocation.limit" $rpSpec.cpuAllocation.limit
		Write-Host "$rpSpec.cpuAllocation.overheadLimit" $rpSpec.cpuAllocation.overheadLimit
		Write-Host "$rpSpec.cpuAllocation.expandableReservation" $rpSpec.cpuAllocation.expandableReservation
	
	
	}
	
	return $rpSpec
}

function ImportClusterConfig($item, $parent, $name)
{
	$spec = New-Object Vmware.Vim.ClusterConfigSpecEx

	###   DAS CONFIG ###
	foreach ($dasConfig in $item.SelectNodes(".//ClusterSettings/dasConfig")) 
	{
		$spec.dasConfig = New-Object Vmware.Vim.ClusterDasConfigInfo   
		$spec.dasConfig.admissionControlEnabled = $dasConfig.admissionControlEnabled
		$spec.dasConfig.defaultVmSettings = New-Object Vmware.Vim.ClusterDasVmSettings  
		$spec.dasConfig.defaultVmSettings.isolationResponse 		= $dasConfig.selectSingleNode("defaultVmSettings").selectSingleNode("isolationResponse").get_InnerXML()
		$spec.dasConfig.defaultVmSettings.restartPriority 			= $dasConfig.selectSingleNode("defaultVmSettings").selectSingleNode("restartPriority").get_InnerXML()
		
		$spec.dasConfig.defaultVmSettings.vmToolsMonitoringSettings = New-Object Vmware.Vim.ClusterVmToolsMonitoringSettings
		$spec.dasConfig.defaultVmSettings.vmToolsMonitoringSettings.clusterSettings 	= $dasConfig.selectSingleNode("defaultVmSettings").selectSingleNode("vmToolsMonitoringSettings").selectSingleNode("clusterSettings").get_InnerXML()
		$spec.dasConfig.defaultVmSettings.vmToolsMonitoringSettings.enabled				= $dasConfig.selectSingleNode("defaultVmSettings").selectSingleNode("vmToolsMonitoringSettings").selectSingleNode("enabled").get_InnerXML()
		$spec.dasConfig.defaultVmSettings.vmToolsMonitoringSettings.failureInterval		= $dasConfig.selectSingleNode("defaultVmSettings").selectSingleNode("vmToolsMonitoringSettings").selectSingleNode("failureInterval").get_InnerXML()
		$spec.dasConfig.defaultVmSettings.vmToolsMonitoringSettings.maxFailureWindow	= $dasConfig.selectSingleNode("defaultVmSettings").selectSingleNode("vmToolsMonitoringSettings").selectSingleNode("maxFailureWindow").get_InnerXML()
		$spec.dasConfig.defaultVmSettings.vmToolsMonitoringSettings.maxFailures			= $dasConfig.selectSingleNode("defaultVmSettings").selectSingleNode("vmToolsMonitoringSettings").selectSingleNode("maxFailures").get_InnerXML()
		$spec.dasConfig.defaultVmSettings.vmToolsMonitoringSettings.minUpTime			= $dasConfig.selectSingleNode("defaultVmSettings").selectSingleNode("vmToolsMonitoringSettings").selectSingleNode("minUpTime").get_InnerXML()
		$spec.dasConfig.defaultVmSettings.vmToolsMonitoringSettings.vmMonitoring		= $dasConfig.selectSingleNode("defaultVmSettings").selectSingleNode("vmToolsMonitoringSettings").selectSingleNode("vmMonitoring").get_InnerXML()
		
		$spec.dasConfig.enabled 		=  $dasConfig.enabled
		$spec.dasConfig.failoverLevel 	=  $dasConfig.failoverLevel
		$spec.dasConfig.hostMonitoring 	=  $dasConfig.hostMonitoring
		$spec.dasConfig.vmMonitoring 	=  $dasConfig.vmMonitoring
		$spec.dasConfig.option 			=  ImportAdvancedOptions $dasConfig
		
		
		Write-Host "DAS: "
		Write-Host "DAS Setting:" $spec.dasConfig.defaultVmSettings.vmToolsMonitoringSettings.enabled 		
		Write-Host "DAS Setting:" $spec.dasConfig.defaultVmSettings.vmToolsMonitoringSettings.clusterSettings
		Write-Host "DAS Setting:" $spec.dasConfig.defaultVmSettings.vmToolsMonitoringSettings.failureInterval 
		Write-Host "DAS Setting:" $spec.dasConfig.defaultVmSettings.vmToolsMonitoringSettings.maxFailureWindow
		Write-Host "DAS Setting:" $spec.dasConfig.defaultVmSettings.vmToolsMonitoringSettings.maxFailures
		Write-Host "DAS Setting:" $spec.dasConfig.defaultVmSettings.vmToolsMonitoringSettings.minUpTime
		Write-Host "DAS Setting:" $spec.dasConfig.defaultVmSettings.vmToolsMonitoringSettings.vmMonitoring
		Write-Host "DAS Setting:" $spec.dasConfig.enabled 		
		Write-Host "DAS Setting:" $spec.dasConfig.vmMonitoring 
		Write-Host "DAS Setting:" $spec.dasConfig.hostMonitoring 
		Write-Host "DAS Setting:" $spec.dasConfig.failoverLevel 
		
	
	}
	
	foreach ($dasVmObj in $item.SelectNodes(".//ClusterSettings/dasVmConfig")) 
	{
		$i=0		
		
		$spec.dasVMConfigSpec += new-object VMware.Vim.ClusterDasVmConfigSpec
 		$spec.dasVMConfigSpec[$i].info = new-object Vmware.Vim.ClusterDasVmConfigInfo
		$spec.dasVMConfigSpec[$i].info.dasSettings = new-object VMware.Vim.ClusterDasVmSettings
		$spec.dasVMConfigSpec[$i].info.key = nul
		
		$dsaSettings = $dasVmObj.selectSingleNode("info").selectSingleNode("dasSettings").get_InnerXML()
		$key =  $dasVmObj.selectSingleNode("info").selectSingleNode("key").get_InnerXML()
 		$spec.dasVMConfigSpec[$i].info.dasSettings.isolationResponse = $dsaSettings.isolationResponse
  		$spec.dasVMConfigSpec[$i].info.dasSettings.restartPriority = $dsaSettings.restartPriority
		$spec.dasVMConfigSpec[$i].info.key.value = $key.Value
		$i++
	}
	


	### DPM CONFIG   ###
	foreach ($dpmConfig in $item.SelectNodes(".//ClusterSettings/dpmConfig")) {
	
		$spec.dpmConfig = New-Object Vmware.Vim.ClusterDpmConfigInfo
		$spec.dpmConfig.defaultDpmBehavior = $dpmConfig.defaultDpmBehavior
		$spec.dpmConfig.enabled = $dpmConfig.enabled
		$spec.dpmConfig.hostPowerActionRate = $dpmConfig.hostPowerActionRate
		$spec.dpmConfig.option = ImportAdvancedOptions $dpmConfig
	
		Write-Host "DPM: "
		Write-Host "$spec.dpmConfigInfo.enabled " $spec.dpmConfig.enabled
		Write-Host "$spec.dpmConfigInfo.defaultDpmBehavior " $spec.dpmConfig.defaultDpmBehavior
		Write-Host "$spec.dpmConfigInfo.hostPowerActionRate " $spec.dpmConfig.hostPowerActionRate
			
	
	}

	foreach ($dpmHostConfig in $item.SelectNodes(".//ClusterSettings/dpmHostConfig")) {
#		Write-Host "DPM HOST"
#		$i = 0
#		$hostObjs = $dpmHostConfig.SelectNodes(".//host")
#		foreach ($hostObj in $hostObjs)
#		{
#			$spec.dpmHostConfigSpec += new-object VMware.Vim.ClusterDpmHostConfigSpec
#  			$spec.dpmHostConfigSpec[$i].info = new-object Vmware.Vim.ClusterDpmHostConfigInfo
#			$spec.dpmHostConfigSpec[$i].info.behavior = $hostObj.behavior
#			Write-Host "behavior: " $spec.dpmHostConfigSpec[$i].info.behavior
#				
#			$spec.dpmHostConfigSpec[$i].info.enabled = $hostObj.enabled
#			Write-Host "enabled: " $spec.dpmHostConfigSpec[$i].info.enabled
#			
#			$spec.dpmHostConfigSpec[$i].info.key = $hostObj.key
#			Write-Host "key: " $spec.dpmHostConfigSpec[$i].info.key
#			
#			
#	
#			$i++
#		}
#		
#	}

	foreach ($drsConfig in $item.SelectNodes(".//ClusterSettings/drsConfig")) {
	
		Write-Host "DRS: "
	
		$spec.drsConfig = New-Object Vmware.Vim.ClusterDrsConfigInfo
		$spec.drsConfig.defaultVmBehavior = $drsConfig.defaultVmBehavior
		$spec.drsConfig.enableVmBehaviorOverrides = $drsConfig.enableVmBehaviorOverrides
		$spec.drsConfig.enabled = $drsConfig.enabled
		$spec.drsConfig.option = ImportAdvancedOptions $drsConfig
		$spec.drsConfig.vmotionRate = $drsConfig.vmotionRate
		
		Write-Host "vmotionRate " $spec.drsConfig.vmotionRate
		Write-Host "defaultVmBehavior " $spec.drsConfig.defaultVmBehavior
		Write-Host "enableVmBehaviorOverrides " $spec.drsConfig.enableVmBehaviorOverrides
		Write-Host "enabled " $spec.drsConfig.enabled
		
		
	
	}
	
	foreach ($drsVmObj in $item.SelectNodes(".//ClusterSettings/drsVmConfig")) 
	{
		$ii=0		
		
		$spec.drsVmConfigSpec += new-object VMware.Vim.ClusterDrsVmConfigSpec
 		$spec.drsVmConfigSpec[$ii].info = new-object Vmware.Vim.ClusterDrsVmConfigInfo
		
		$info = $drsVmObj.selectSingleNode("info").get_InnerXML()
 		$spec.dasVMConfigSpec[$ii].info.behavior = $info.behavior
  		$spec.dasVMConfigSpec[$ii].info.enabled = $info.enabled
		$spec.dasVMConfigSpec[$ii].info.key = Get-VM -Name "SteveVM"
		$ii++
	}
	
	
	
	
$k = 0
	foreach ($group in $item.SelectNodes(".//groups/vmGroup"))
	{
		$spec.groupSpec += New-Object VMware.Vim.ClusterGroupSpec
		$spec.groupSpec[$k].info = New-Object Vmware.Vim.ClusterVmGroup
		$spec.groupSpec[$k].info.name = $group.name	
	#	$spec.groupSpec[$k].info.vm = $group.vms

			
		Write-Host "Group: " 
		Write-Host "Group Name " $spec.groupSpec[$k].info.name
#		Write-Host "VMs " $spec.groupSpec[$k].info.vm
		$k++
	
	}
	
	$l = 0
	foreach ($group in $item.SelectNodes(".//groups/hostGroup"))
	{
		$spec.groupSpec += New-Object VMware.Vim.ClusterGroupSpec
		$spec.groupSpec[$l].info = New-Object Vmware.Vim.ClusterHostGroup
		$spec.groupSpec[$l].info.name = $group.name	
		#$spec.groupSpec[$l].info.host = $group.host

			
		Write-Host "Group: " 
		Write-Host "Group Name " $spec.groupSpec[$l].info.name
#		Write-Host "Hosts " $spec.groupSpec[$l].info.host
		$l++
	
	}
		
		
	$j = 0
	foreach ($rule in $item.SelectNodes(".//rules/rule")) {

		$spec.rulesSpec += New-Object VMware.Vim.ClusterRuleSpec
		$spec.rulesSpec[$j].info = New-Object Vmware.Vim.ClusterRuleInfo 
		$spec.rulesSpec[$j].info.enabled = $rule.enabled
		$spec.rulesSpec[$j].info.key = $rule.key
		$spec.rulesSpec[$j].info.inCompliance = $rule.inCompliance
		$spec.rulesSpec[$j].info.mandatory = $rule.mandatory
		$spec.rulesSpec[$j].info.status = $rule.status
		$spec.rulesSpec[$j].info.name = $rule.name
		$spec.rulesSpec[$j].info.userCreated = $rule.userCreated
		
		Write-Host "RULES " 
		Write-Host "enabled " $spec.rulesSpec[$j].info.enabled
		Write-Host "key " $spec.rulesSpec[$j].info.key
		Write-Host "InCompliance " $spec.rulesSpec[$j].info.inCompliance
		Write-Host "Mandatory " $spec.rulesSpec[$j].info.mandatory
		Write-Host "status " $spec.rulesSpec[$j].info.status
		Write-Host "Name " $spec.rulesSpec[$j].info.name
		Write-Host "User Created " $spec.rulesSpec[$j].info.userCreated
		
		$j++
	}
	return $spec
}

function ImportAdvancedOptions ($obj)
{
	Write-Host "ImportAdvancedOptions" $obj.admissionControlEnabled

	[Vmware.Vim.OptionValue[]]$optionValues = @()

	foreach ($option in $obj.SelectNodes(".//Options/option")) 
	{
		$optionValue = New-Object Vmware.Vim.OptionValue
		$optionValue.Key = $option.key
		$optionValue.Value = $option.value
		$optionValues = $optionValues + $optionValue	
		
		Write-Host "optionValue Value: " $optionValue.Value -ForegroundColor  DarkRed
		Write-Host "optionValue Key: " $optionValue.Key  -ForegroundColor DarkRed
		
	}
	Write-Host "ImportAdvancedOptions end"
	return $optionValues
	
	
}


# EOF ----------------------------------------------------------------------------------------------
 
