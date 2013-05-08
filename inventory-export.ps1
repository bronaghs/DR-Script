--------------------------------------------------------------------------------------------------
# inventory-export.ps1
# This script exports the Folder/Datacenter hierarchy from the current VC into an xml file, including # the permissions defined in each folder or datacenter 
#
# name:		inventory-export.ps1
# args:		vCenter server , outputFile [optional]
# how to run:	from an existing session to a VC
#			PS C:\Scripts> .\inventory-export.ps1
#---------------------------------------------------------------------------------------------------

#Disconnect first from vCenter in case a connection already exists.

param($vCenter, $outputFile)
Disconnect-VIServer $vCenter -Confirm

$invRoot = "/"

function GetInventoryItem($MoRef, $dirPath){

	# This is a recursive function so the first time it is called $MoRef is a reference to the root folder
	# of the hierarchy. As the inventory tree is traversed a reference to each managed entity is passed as an argument 
	# to this function and processed according to what type it is.

	switch ($MoRef.Type) {
		"Folder" {
			# If the managed entity is a folder an XML entry is appended to the XML file
			# and each child entity of the folder is passed as an argument to this function 
			# and processed.

			$obj = get-view -property Name,ChildEntity,childType $MoRef;
			$currentPath = $dirPath
			CreateXMLEntry $obj $dirPath
			if ($dirPath -eq "" -or $dirPath -eq "/") {
				$currentPath += "/"
			}
			else {
				$currentPath += "/" + $obj.Name
			}

			# REcurse through each child entity of the folder. Could be a VM, host, Cluster, Datacenter...
			$obj.childEntity | foreach{GetInventoryItem $_ $currentPath};
		}
		"Datacenter" {

			# Retrieve all the child nodes of a datacenter by pulling the variables: vmFolder
			# hostFolder, datastoreFolder. Refer to the MOB browser to see exactly which managed 
			# entities in your environment that will be returned by these variables.

			$obj = get-view -property Name,vmFolder,hostFolder, datastoreFolder $MoRef;
			$currentPath = $dirPath

			# Create an XML entry for this node.
			CreateXMLEntry $obj $currentPath

			# the following 3 properties of the datacenter (vm, host, datastore) refer to the 
			# path in the hierarchy of where to find the child nodes of a Datacenter. We do not 
			# need to create an XML entry for these folders since they are automatically created
			# but we need to traverse through them to get their child nodes.

			$vmFolder = get-view $obj.vmFolder -property childEntity
			$hsFolder = get-view $obj.hostFolder -property childEntity
			$dsFolder = get-view $obj.datastoreFolder -property childEntity

			$vmcurrentPath += "/" + $obj.Name + "/vm"
			$hscurrentPath += "/" + $obj.Name + "/host"
			$dscurrentPath += "/" + $obj.Name + "/datastore"

			# Call this GetInventoryItem function recursively to process the child entities
			# of the vmFolder, hostFolder, datastoreFolder.
			$vmFolder.childEntity | foreach {GetInventoryItem $_ $vmcurrentPath};
			$hsFolder.childEntity | foreach {GetInventoryItem $_ $hscurrentPath};
			$dsFolder.childEntity | foreach {GetInventoryItem $_ $dscurrentPath};
		}

		"HostSystem" {
			$obj = Get-View -Property Name $MoRef
			$currentPath = $dirPath
			CreateXMLEntry $obj $currentPath
		}
		"ComputeResource" {
			$obj = Get-View -Property Name, resourcePool $MoRef
			$currentPath = $dirPath
			CreateXMLEntry $obj $currentPath
		}
		"ClusterComputeResource" {

			# ClusterComputeResource object has multiple child node types. As well as 
			# resource pools and hosts the configuration parameters must be saved, for example:
			# DAS (high availability service)
			# DPM (distributed power module)
			# DRS (distributed resource scheduling)


			$obj = Get-View -Property Name, host, resourcePool, configurationEx, summary $MoRef
			$currentPath = $dirPath
			CreateXMLEntry $obj $currentPath
			$hostscurrentPath += $currentPath + "/" + $obj.Name

			# Get a list of hosts, resource pools in the cluster and recursively call this function to 
			# process the child nodes (hosts, resource pools)
			$obj.host | foreach {GetInventoryItem $_ $hostscurrentPath};

			$clstRpcurrentPath = $currentPath + "/" + $obj.Name 

			$rp = Get-View $obj.resourcePool
			$rp.resourcePool | foreach {GetInventoryItem $_ $clstRpcurrentPath};
		}
		"ResourcePool" {
			$obj = Get-View -Property Name, resourcePool, config, vm $MoRef
			$currentPath = $dirPath
			CreateXMLEntry $obj $currentPath
			if ($obj.resourcePool)
			{
				$rpcurrentPath += $currentPath + "/Resources/" + $obj.Name 
				Write-Host "rp current path : " $rpcurrentPath -ForegroundColor Red
				$obj.resourcePool | foreach {GetInventoryItem $_ $rpcurrentPath};
			}

		}
		"Datastore" {
			$obj = Get-View -Property Name $MoRef
			$currentPath = $dirPath
			CreateXMLEntry $obj $currentPath

		}
	}
}
function CreateXMLEntry($invObj, $invPath){

	$item = $xml.CreateElement("item");
	$itemList.AppendChild($item);

	$name = $xml.CreateElement("name")
	$name.set_InnerText($invObj.Name)
	$item.AppendChild($name)

	$type = $xml.CreateElement("type")
	$type.set_InnerText($invObj.MoRef.Type)
	$item.AppendChild($type)

	$path = $xml.CreateElement("path")
	$path.set_InnerText($invPath)
	$item.AppendChild($path)


	if ($invObj.MoRef.Type -eq "ResourcePool")
	{
		$rpSettings = $xml.CreateElement("RPSettings")
		$item.AppendChild($rpSettings)
		ExportRPSettings $invObj

		$vms = $invObj.vm

		foreach ($vm in $vms)
		{
			$view = Get-View -ID $vm
			$vmTag = $xml.CreateElement("VM") 
			$item.AppendChild($vmTag)
			$vmNameTag = $xml.CreateElement("Name") 
			$vmNameTag.set_InnerText($view.Name)
			$vmTag.AppendChild($vmNameTag)

		}

	}
	elseIf ($invObj.MoRef.Type -eq "ClusterComputeResource")
	{
		$evcModeTag = $xml.CreateElement("EVCMode")
		$item.AppendChild($evcModeTag)
		$evcModeTag.set_InnerText($invObj.summary.currentEVCModeKey)

		$clst = $xml.CreateElement("ClusterSettings")
		$item.AppendChild($clst)

		ExportDasSettings $invObj
		ExportDpmSettings $invObj

		$dasVmConfig = $xml.CreateElement("dasVmConfig")
		$dasVmConfig.set_InnerText($invObj.configurationEx.dasVmConfig)
		$clst.AppendChild($dasVmConfig)

		ExportDrsSettings $invObj

		$drsVmConfig = $xml.CreateElement("drsVmConfig")
		$drsVmConfig.set_InnerText($invObj.configurationEx.drsVmConfig)
		$clst.AppendChild($drsVmConfig)

		$rules = $xml.CreateElement("rules")
		$clst.AppendChild($rules)
		$clstVmRulesObj = $invObj.configurationEx.rule
		foreach ($rule in $clstVmRulesObj){

			$ruleSpec = $xml.CreateElement("rule")
			$rules.AppendChild($ruleSpec)

			$RulesEnabled = $xml.CreateElement("enabled")
			$RulesEnabled.set_InnerText($rule.enabled)
			$ruleSpec.AppendChild($RulesEnabled)

			$inCompliance = $xml.CreateElement("inCompliance")
			$inCompliance.set_InnerText($rule.inCompliance)
			$ruleSpec.AppendChild($inCompliance)

			$key = $xml.CreateElement("key")
			$key.set_InnerText($rule.key)
			$ruleSpec.AppendChild($key)

			$mandatory = $xml.CreateElement("mandatory")
			$mandatory.set_InnerText($rule.mandatory)
			$ruleSpec.AppendChild($mandatory)

			$name = $xml.CreateElement("name")
			$name.set_InnerText($rule.name)
			$ruleSpec.AppendChild($name)

			$status = $xml.CreateElement("status")
			Write-Host "Status: " $rule.status -ForegroundColor DarkCyan 
			if (!$rule.status)
			{
				$status.set_InnerText("gray")
			}
			else
			{
				$status.set_InnerText($rule.status)
			}
			$ruleSpec.AppendChild($status)
			$userCreated = $xml.CreateElement("userCreated")
			$userCreated.set_InnerText($rule.userCreated)
			$ruleSpec.AppendChild($userCreated)

			foreach ($vmObj in $rule.vm){

				$vm = $xml.CreateElement("vm")
				$vm.set_InnerText($vmObj.value)
				$ruleSpec.AppendChild($vm)
			}
		}

		#		 the groups below will only be created for vSphere 4.1.1
		#		---------------------------------------------

		$groups = $xml.CreateElement("groups")
		$clst.AppendChild($groups) 
		$clstGrpObj = $invObj.configurationEx.group

		foreach ($grp in $clstGrpObj){
			if (!$grp)
			{
				continue;
			}

			if ($grp.ToString() -eq "VMware.Vim.ClusterVmGroup")
			{
				$vmGroup = $xml.CreateElement("vmGroup")

				$name = $xml.CreateElement("name")
				$name.set_InnerText($grp.name)
				$vmGroup.AppendChild($name)

				$vms = $xml.CreateElement("vms")
				$vms.set_InnerText($grp.vm)
				$vmGroup.AppendChild($vms)

				$groups.AppendChild($vmGroup)
			}
			elseif ($grp.ToString() -eq "VMware.Vim.ClusterHostGroup")
			{
				$hostGroup = $xml.CreateElement("hostGroup")
				$name = $xml.CreateElement("name")
				$name.set_InnerText($grp.name)
				$hostGroup.AppendChild($name)

				$hosts = $xml.CreateElement("host")
				$hosts.set_InnerText($grp.host)
				$hostGroup.AppendChild($hosts)
				$groups.AppendChild($hostGroup)
			}
		}

		$vmSwapPlacement = $xml.CreateElement("vmSwapPlacement")
		$vmSwapPlacement.set_InnerText($invObj.configurationEx.vmSwapPlacement)
		$clst.AppendChild($vmSwapPlacement)
	}


	$childType = $xml.CreateElement("childtype")
	if ($invObj.MoRef.Type -eq "Folder") {
		$childType.set_InnerText($invObj.childType[1])
	}
	$item.AppendChild($childType)

	#----- Export the permissions associated with each entity -----#
	$permissionList = $xml.CreateElement("permissions")
	$item.AppendChild($permissionList)

	$perm = $authMgr.RetrieveEntityPermissions($invObj.MoRef, 0)
	foreach($p in $perm) {
		$permission = $xml.CreateElement("permission")
		$permissionList.AppendChild($permission)

		$role = $xml.CreateElement("role")
		$role.set_InnerText($roleHash[$p.RoleId])
		$permission.AppendChild($role)

		$principal = $xml.CreateElement("principal")
		$principal.set_InnerText($p.Principal)
		$permission.AppendChild($principal)

		$propagate = $xml.CreateElement("propagate")
		$propagate.set_InnerText($p.Propagate)
		$permission.AppendChild($propagate)

		$group = $xml.CreateElement("group") 
		if ($p.Group) {
			$group.set_InnerText("True")
		} 
		else {
			$group.set_InnerText("False")
		}
		$permission.AppendChild($group)
	}

	ExportAlarmDefinitions($invObj)

}

function CreateXMLElement( $valueParam, $childStr)
{
	$child = $xml.CreateElement($childStr)
	if (!$valueParam)
	{
		return $child
	}

	$child.set_InnerText($valueParam)

	return $child
}

function ExportDefaultAlarmExpression ($expression)
{
	$expressionHeader = $xml.CreateElement("Expression")
	$defElement.AppendChild($expressionHeader)

	$element = CreateXMLElement $expression.ToString() "expressionType"
	$expressionHeader.AppendChild($element)

	$comparisonList = $expression.comparisons
	foreach ($comparison in $comparisonList)
	{
		#		$attribute = $comparison.attributeName
		#		$operator = $comparison.operator
		#		$value = $comparison.value
		#		
		$compHeader = $xml.CreateElement("Comparison")
		$expressionHeader.AppendChild($compHeader)


		$element = CreateXMLElement $comparison.attributeName "attributeName"
		$compHeader.AppendChild($element)
		$element = CreateXMLElement $comparison.operator "operator"
		$compHeader.AppendChild($element)
		$element = CreateXMLElement $comparison.value "value"
		$compHeader.AppendChild($element)


	}

	#	$element= CreateXMLElement  $expression.eventTypeId  "eventTypeId"
	#	$defElement.AppendChild($element)
	$element = CreateXMLElement $expression.eventType "eventType"
	$expressionHeader.AppendChild($element)
	$element = CreateXMLElement $expression.status "status"
	$expressionHeader.AppendChild($element)
	$element = CreateXMLElement $expression.objectType "objectType"
	$expressionHeader.AppendChild($element)

}


function ExportAlarmDefinitions($invObj)
{
 
#------- Get the alarm definitions associated with each entity ---#
if ($invObj.MoRef.Type -eq "ComputeResource")
{
	continue
}

# Get the alarm definitions for this entity. This is called for all inventory objects
# Eg If CPU Utilization is greater than 75% generate an orange alert but if it is 
# greater than 85% generate a red alert.

$alarmDefinitions = Get-AlarmDefinition -Entity (Get-VIObjectByVIView $invObj)


foreach ($alarmDef in $alarmDefinitions)
{
	if (!$alarmDef)
	{
		continue
	}
	$alarmActions = $null
	$alarmAction = $null
	if ($invObj.MoRef -ne $alarmDef.Entity.Id){

		#--- only get the alarm definitions created for this node, not inherited ones ---#
		continue

	}

	if ($alarmDef.Description.Contains("Default"))
	{
		#--- Ignore default alarm definitions ----#
		continue
	}
	$defElement = $xml.CreateElement("AlarmDefinition")
	$item.AppendChild($defElement)

	$element = CreateXMLElement $alarmDef.Description "Description"
	$defElement.AppendChild($element)

	$element = CreateXMLElement $alarmDef.Enabled "Enabled"
	$defElement.AppendChild($element)

	$element = CreateXMLElement $alarmDef.ActionRepeatMinutes "ActionRepeatMinutes"
	$defElement.AppendChild($element)

	$element = CreateXMLElement $alarmDef.ExtensionData.Setting.ToleranceRange "ToleranceRange"
	$defElement.AppendChild($element)

	$element = CreateXMLElement $alarmDef.ExtensionData.Setting.ReportingFrequency "reportingFrequency"
	$defElement.AppendChild($element)

	$element = CreateXMLElement $alarmDef.name "Name"
	$defElement.AppendChild($element)


	$expressions = $alarmDef.ExtensionData.expression.expression

	$element = CreateXMLElement $alarmDef.ExtensionData.expression "ExpressionOperator"
	$defElement.AppendChild($element)


	$alarmActions = $alarmDef.ExtensionData.Action.Action


	foreach ($expression in $expressions)
	{
		if (!$expression)
		{
			continue
		}
		# --- Trigger section ----#
		if ($expression.ToString().Contains("MetricAlarmExpression"))
		{

			$expressionHeader = $xml.CreateElement("Expression")
			$defElement.AppendChild($expressionHeader)

			$element = CreateXMLElement $expression.ToString() "expressionType"
			$expressionHeader.AppendChild($element)
			$element = CreateXMLElement $expression.Metric.CounterId "CounterId"
			$expressionHeader.AppendChild($element)
			$element = CreateXMLElement $expression.Metric.Instance "instance"
			$expressionHeader.AppendChild($element)
			$element = CreateXMLElement $expression.operator "operator"
			$expressionHeader.AppendChild($element)
			$element = CreateXMLElement $expression.red "red"
			$expressionHeader.AppendChild($element)
			$element = CreateXMLElement $expression.redInterval "redInterval"
			$expressionHeader.AppendChild($element)
			$element = CreateXMLElement $expression.yellow "yellow"
			$expressionHeader.AppendChild($element)
			$element = CreateXMLElement $expression.yellowInterval "yellowInterval"
			$expressionHeader.AppendChild($element)
			$element = CreateXMLElement $expression.type "type"
			$expressionHeader.AppendChild($element)
		}
		elseif ($expression.ToString().Contains("EventAlarmExpression"))
		{
			ExportDefaultAlarmExpression $expression
		}
		elseif ($expression.ToString().Contains("StateAlarmExpression"))
		{
			$expressionHeader = $xml.CreateElement("Expression")
			$defElement.AppendChild($expressionHeader)

			$element = CreateXMLElement $expression.ToString() "expressionType"
			$expressionHeader.AppendChild($element)

			$element = CreateXMLElement $expression.operator "operator"
			$expressionHeader.AppendChild($element)

			$element = CreateXMLElement $expression.red "red"
			$expressionHeader.AppendChild($element)

			$element = CreateXMLElement $expression.yellow "yellow"
			$expressionHeader.AppendChild($element)

			$element = CreateXMLElement $expression.statePath "statePath"
			$expressionHeader.AppendChild($element)

			$element = CreateXMLElement $expression.type "type"
			$expressionHeader.AppendChild($element)
		}
	}

	# What action to take if this alarm is fired eg generate a SNMP trat or
	# Send an email.

	foreach ($alarmAction in $alarmActions)
	{
		if (!$alarmAction)
		{
			continue
		}

		$actionHeader = $xml.CreateElement("Action")
		$defElement.AppendChild($actionHeader)

		$element = CreateXMLElement $alarmAction.Action.ToString() "actionType"
		$actionHeader.AppendChild($element)


		switch ($alarmAction.Action)
		{
			VMware.Vim.RunScriptAction {

				$element = CreateXMLElement $alarmAction.Action.Script "scriptFilePath"
				$actionHeader.AppendChild($element)
			}
			VMware.Vim.SendEmailAction {
				$element = CreateXMLElement $alarmAction.Action.body "body"
				$actionHeader.AppendChild($element)

				$ccList =$alarmAction.Action.ccList
				foreach ($ccAddr in $ccList)
				{
					$element = CreateXMLElement $ccAddr "cc"
					$actionHeader.AppendChild($element)
				}

				$toList =$alarmAction.Action.toList
				foreach ($toAddr in $toList)
				{
					$element = CreateXMLElement $toAddr "to"
					$actionHeader.AppendChild($element)
				}
				$element = CreateXMLElement $alarmAction.Action.subject "subject"
				$actionHeader.AppendChild($element)


			}
			VMware.Vim.SendSNMPAction {
			}
			VMware.Vim.MethodAction 
			{
				$element = CreateXMLElement $alarmAction.Action.Name "Name"
				$actionHeader.AppendChild($element)
			}
			default {
			}
		}

		$transactionSpecs = $alarmAction.TransitionSpecs
		foreach ($tSpec in $transactionSpecs)
		{
			$tSpecHeader = $xml.CreateElement("TransitionSpec")
			$actionHeader.AppendChild($tSpecHeader)

			$element = CreateXMLElement $tSpec.startState "startState"
			$tSpecHeader.AppendChild($element)

			$element = CreateXMLElement $tSpec.finalState "finalState"
			$tSpecHeader.AppendChild($element)

			$element = CreateXMLElement $tSpec.repeats.toString() "repeats"
			$tSpecHeader.AppendChild($element)
		}

		$element = CreateXMLElement $alarmAction.green2yellow.toString() "green2yellow"
		$actionHeader.AppendChild($element)
		$element = CreateXMLElement $alarmAction.red2yellow.toString() "red2yellow"
		$actionHeader.AppendChild($element)
		$element = CreateXMLElement $alarmAction.yellow2green.toString() "yellow2green"
		$actionHeader.AppendChild($element)
		$element = CreateXMLElement $alarmAction.yellow2red.toString() "yellow2red"
		$actionHeader.AppendChild($element)
	} 
}
}

function ExportDasSettings($invObj)
{
	# This exports all the DAS (high availability settings) to the XML file. This is called 
	# for only the clusterComputeResource

	$dasConfig = $xml.CreateElement("dasConfig")
	$clst.AppendChild($dasConfig)
	
	$admissionControlEnabled = $xml.CreateElement("admissionControlEnabled")
	$admissionControlEnabled.set_InnerText($invObj.configurationEx.dasConfig.admissionControlEnabled)
	$dasConfig.AppendChild($admissionControlEnabled)
	
	$failoverLevel = $xml.CreateElement("failoverLevel")
	$failoverLevel.set_InnerText($invObj.configurationEx.dasConfig.admissionControlPolicy.failoverLevel)
	$dasConfig.AppendChild($failoverLevel)
	
	# DEFAULT VM SETTINGS
	$defaultVmSettings = $xml.CreateElement("defaultVmSettings")
	$isolationResponse = $xml.CreateElement("isolationResponse")
	$restartPriority = $xml.CreateElement("restartPriority")
	$vmToolsMonitoringSettings = $xml.CreateElement("vmToolsMonitoringSettings")
	
	$defaultVMsettingsObj = $invObj.configurationEx.dasConfig.defaultVmSettings;
	$isolationResponse.set_InnerText($defaultVMsettingsObj.isolationResponse)
	$restartPriority.set_InnerText($defaultVmSettingsObj.restartPriority)
	
	$clusterSettings = $xml.CreateElement("clusterSettings")
	$defaultVMEnabled = $xml.CreateElement("enabled")
	$failureInterval = $xml.CreateElement("failureInterval")
	$maxFailureWindow = $xml.CreateElement("maxFailureWindow")
	$maxFailures = $xml.CreateElement("maxFailures")
	$minUpTime = $xml.CreateElement("minUpTime")
	$vmMonitoring = $xml.CreateElement("vmMonitoring")
	
	$clusterSettings.set_InnerText($defaultVMsettingsObj.vmToolsMonitoringSettings.clusterSettings)
	$defaultVMEnabled.set_InnerText($defaultVMsettingsObj.vmToolsMonitoringSettings.enabled)
	$failureInterval.set_InnerText($defaultVMsettingsObj.vmToolsMonitoringSettings.failureInterval)
	$maxFailureWindow.set_InnerText($defaultVMsettingsObj.vmToolsMonitoringSettings.maxFailureWindow)
	$maxFailures.set_InnerText($defaultVMsettingsObj.vmToolsMonitoringSettings.maxFailures)
	$minUpTime.set_InnerText($defaultVMsettingsObj.vmToolsMonitoringSettings.minUpTime)
	$vmMonitoring.set_InnerText($defaultVMsettingsObj.vmToolsMonitoringSettings.vmMonitoring)
	
	$vmToolsMonitoringSettings.AppendChild($clusterSettings)
	$vmToolsMonitoringSettings.AppendChild($defaultVMEnabled)
	$vmToolsMonitoringSettings.AppendChild($failureInterval)
	$vmToolsMonitoringSettings.AppendChild($maxFailureWindow)
	$vmToolsMonitoringSettings.AppendChild($maxFailures)
	$vmToolsMonitoringSettings.AppendChild($minUpTime)
	$vmToolsMonitoringSettings.AppendChild($vmMonitoring)
	
	$defaultVmSettings.AppendChild($isolationResponse)
	$defaultVmSettings.AppendChild($restartPriority)
	$defaultVmSettings.AppendChild($vmToolsMonitoringSettings)
	$dasConfig.AppendChild($defaultVmSettings)
	
	#	$failoverLevel = $xml.CreateElement("failoverLevel")
	#	$failoverLevel.set_InnerText($invObj.configurationEx.dasConfig.failoverLevel)
	#	$dasConfig.AppendChild($failoverLevel)
	
	$hostMonitoring = $xml.CreateElement("hostMonitoring")
	$hostMonitoring.set_InnerText($invObj.configurationEx.dasConfig.hostMonitoring)
	$dasConfig.AppendChild($hostMonitoring)
	
	$dasEnabled = $xml.CreateElement("enabled")
	$dasEnabled.set_InnerText($invObj.configurationEx.dasConfig.enabled)
	$dasConfig.AppendChild($dasEnabled)
	
	$dasOptionsObj = $invObj.configurationEx.dasConfig.option
	$dasOptions = $xml.CreateElement("Options")
	$dasConfig.AppendChild($dasOptions)
	
	foreach ($options in $dasOptionsObj)
	{
		$option = $xml.CreateElement("option")
		$optKey = $xml.CreateElement("key")
		$optKey.set_InnerText($options.Key)
		$option.AppendChild($optKey)
	
		$optValue = $xml.CreateElement("value")
		$optValue.set_InnerText($options.Value)
		$option.AppendChild($optValue)
	
		$dasOptions.AppendChild($option)
	}
	
	$vmMonitoring = $xml.CreateElement("vmMonitoring")
	$vmMonitoring.set_InnerText($invObj.configurationEx.dasConfig.vmMonitoring)
	$dasConfig.AppendChild($vmMonitoring)
	}
	
	function ExportDrsSettings($invObj)
	{
 		$drsConfig = $xml.CreateElement("drsConfig")
		$clst.AppendChild($drsConfig)

		$defaultVmBehavior = $xml.CreateElement("defaultVmBehavior")
		$defaultVmBehavior.set_InnerText($invObj.configurationEx.drsConfig.defaultVmBehavior)
		$drsConfig.AppendChild($defaultVmBehavior)

		$enableVmBehaviorOverrides = $xml.CreateElement("enableVmBehaviorOverrides")
		$enableVmBehaviorOverrides.set_InnerText($invObj.configurationEx.drsConfig.enableVmBehaviorOverrides)
		$drsConfig.AppendChild($enableVmBehaviorOverrides)

		$drsEnabled = $xml.CreateElement("enabled")
		$drsEnabled.set_InnerText($invObj.configurationEx.drsConfig.enabled)
		$drsConfig.AppendChild($drsEnabled)

		$drsOptions = $xml.CreateElement("Options")
		$drsOptionsObj = $invObj.configurationEx.drsConfig.option
		foreach ($options in $drsOptionsObj)
		{
			$option = $xml.CreateElement("option")
			$optKey = $xml.CreateElement("key")
			$optKey.set_InnerText($options.Key)
			$option.AppendChild($optKey)

			$optValue = $xml.CreateElement("value")
			$optValue.set_InnerText($options.Value)
			$option.AppendChild($optValue)

			$drsOptions.AppendChild($option)
		}
		$drsConfig.AppendChild($drsOptions)

		$vmotionRate = $xml.CreateElement("vmotionRate")
		$vmotionRate.set_InnerText($invObj.configurationEx.drsConfig.vmotionRate)
		$drsConfig.AppendChild($vmotionRate)
		
		
	}

function ExportDpmSettings($invObj)
{
	$dpmConfigInfoObj = $invObj.configurationEx.dpmConfigInfo
	$dpmConf.ig = $xml.CreateElement("dpmConfig")
	$clst.App.endChild($dpmConfig)

	$defaultDpmBehavior = $xml.CreateElement("defaultDpmBehavior")
	$defaultDpmBehavior.set_InnerText($dpmConfigInfoObj.defaultDpmBehavior)
	$dpmConfig.AppendChild($defaultDpmBehavior)
	
	$enabled = $xml.CreateElement("enabled")
	$enabled.set_InnerText($dpmConfigInfoObj.enabled)
	$dpmConfig.AppendChild($enabled)
	
	$hostPowerActionRate = $xml.CreateElement("hostPowerActionRate")
	$hostPowerActionRate.set_InnerText($dpmConfigInfoObj.hostPowerActionRate)
	$dpmConfig.AppendChild($hostPowerActionRate)
	
	$dpmOptions = $xml.CreateElement("Options")
	$dpmOptionsObj = $invObj.configurationEx.dpmConfig.option
	foreach ($options in $dpmOptionsObj)
	{
		$option = $xml.CreateElement("option")
		$optKey = $xml.CreateElement("key")
		$optKey.set_InnerText($options.Key)
		$option.AppendChild($optKey)
	
		$optValue = $xml.CreateElement("value")
		$optValue.set_InnerText($options.Value)
		$option.AppendChild($optValue)
	
		$dpmOptions.AppendChild($option)
	}
	$dpmConfig.AppendChild($dpmOptions)
	
	#	DPM Host Config
	$dpmHostConfigObj = $invObj.configurationEx.dpmHostConfig
	$dpmHostConfig = $xml.CreateElement("dpmHostConfig")
	foreach ($dpmHostObj in $dpmHostConfigObj)
	{
		$hostTag = $xml.CreateElement("host")
		$behavior = $xml.CreateElement("behavior")
		$behavior.set_InnerText($dpmHostObj.behavior)
		$hostTag.AppendChild($behavior)
	
		$dpmHostEnabled = $xml.CreateElement("enabled")
		$dpmHostEnabled.set_InnerText($dpmHostObj.enabled)
		$hostTag.AppendChild($dpmHostEnabled)
	
		$key = $xml.CreateElement("key")
		$key.set_InnerText($dpmHostObj.key)
		$hostTag.AppendChild($key)
	
		$dpmHostConfig.AppendChild($hostTag)
	}
	$clst.AppendChild($dpmHostConfig)
	}
	
	
	
function ExportRPSettings($invObj)
{
	$resourceCfgSpec = $xml.CreateElement("config")
	$rpSettings.AppendChild($resourceCfgSpec)

	$changeVersion = $xml.CreateElement("changeVersion")
	$changeVersion.set_InnerText($invObj.config.changeVersion) 
	$resourceCfgSpec.AppendChild($changeVersion)
	
	$lastModified = $xml.CreateElement("lastModified")
	$lastModified.set_InnerText($invObj.config.lastModified) 
	$resourceCfgSpec.AppendChild($lastModified)
	
	$entity = $xml.CreateElement("entity")
	$entity.set_InnerText($invObj.config.entity) 
	$resourceCfgSpec.AppendChild($entity)
	
	$cpuAllocationObj = $invObj.config.cpuAllocation
	$memoryAllocationObj = $invObj.config.memoryAllocation
	
	$cpuAllocation = $xml.CreateElement("cpuAllocation")
	$resourceCfgSpec.AppendChild($cpuAllocation)
	$memoryAllocation = $xml.CreateElement("memoryAllocation")
	$resourceCfgSpec.AppendChild($memoryAllocation)
	
	ExportRPAllocationInfo $cpuAllocation $cpuAllocationObj
	ExportRPAllocationInfo $memoryAllocation $memoryAllocationObj

}

function ExportRPAllocationInfo($allocTag, $allocObj)
{


	$expandableReservation = $xml.CreateElement("expandableReservation")
	$expandableReservation.set_InnerText($allocObj.expandableReservation)
	$allocTag.AppendChild($expandableReservation)

	$limit = $xml.CreateElement("limit")
	$limit.set_InnerText($allocObj.limit)
	$allocTag.AppendChild($limit)

	$overheadLimit = $xml.CreateElement("overheadLimit")
	$overheadLimit.set_InnerText($allocObj.overheadLimit)
	$allocTag.AppendChild($overheadLimit)

	$reservation = $xml.CreateElement("reservation")
	$reservation.set_InnerText($allocObj.reservation)
	$allocTag.AppendChild($reservation)

	$shares = $xml.CreateElement("shares")
	$level = $xml.CreateElement("level")
	$level.set_InnerText($allocObj.shares.level)
	$shares.AppendChild($level)

	$sharesNsted = $xml.CreateElement("shares")
	$sharesNsted.set_InnerText($allocObj.shares.shares)
	$shares.AppendChild($sharesNsted)

	$allocTag.AppendChild($shares)
}

function ExportSettings()
{
	$objLicenseManager = Get-View -Id $serviceInstance.Content.licenseManager
	$licenseServer = $objLicenseManager.source.LicenseServer
	$optMgr = Get-View -Id 'OptionManager-VpxSettings' 
	
	$settingsTag = $xml.CreateElement("Settings")
	$root.AppendChild($settingsTag)
	
	#------------- Store the pieces of information we need to export ------------
	$maxDbConnection = ($optMgr.Setting | where{$_.Key -eq "VirtualCenter.MaxDBConnection"}).Value 
	$mailServer = ($optMgr.Setting | where{$_.Key -eq "mail.smtp.server"}).Value 
	$mailSender = ($optMgr.Setting | where{$_.Key -eq "mail.sender"}).Value 
	
	#-------------Build out our xml tags inserting the values above -------------
	$licenseServerTag = $xml.CreateElement("licenseServer")
	$licenseServerTag.set_InnerText($licenseServer)
	$settingsTag.AppendChild($licenseServerTag)
	
	$maxDbConnectionTag = $xml.CreateElement("maxDbConnection")
	$maxDbConnectionTag.set_InnerText($maxDbConnection)
	$settingsTag.AppendChild($maxDbConnectionTag)
	
	$mailServerTag = $xml.CreateElement("mailServer")
	$mailServerTag.set_InnerText($mailServer)
	$settingsTag.AppendChild($mailServerTag)
	
	$mailSenderTag = $xml.CreateElement("mailSender")
	$mailSenderTag.set_InnerText($mailSender)
	$settingsTag.AppendChild($mailSenderTag)

}

function ExportRoles()
{
	$roles = $authMgr.RoleList;

	foreach($r in $roles) {
	if ($r.RoleId -ge 10) {
		$role = $xml.CreateElement("roleProfile");
		$root.AppendChild($role);

		$name = $xml.CreateElement("rolename");
		$name.set_InnerText($r.Name);
		$role.AppendChild($name);

		$id = $xml.CreateElement("id");
		$id.set_InnerText($r.RoleId.ToString());
		$role.AppendChild($id);

		$privs = $xml.CreateElement("privList");
		$role.AppendChild($privs);

		foreach($perm in $r.Privilege) {
			$priv = $xml.CreateElement("priv");
			$priv.set_InnerText($perm);
			$privs.AppendChild($priv);
		}
	}
}
}

# Starting point of the script. 

$xml = New-Object System.Xml.XmlDocument
$dec = $xml.CreateXmlDeclaration("1.0","UTF-8","")
$xml.AppendChild($dec)
$root = $xml.CreateElement("root")
$xml.AppendChild($root)
$itemList = $xml.CreateElement("itemList")
$root.AppendChild($itemList)

# Once the header of the XML export output file has been created, connect to
#the vCenter server. the $vCenter variable is passed in as an argument

Connect-VIServer -Server $vCenter -Protocol https 


$authMgr = get-view AuthorizationManager
$roleHash = @{};
$authMgr.RoleList | foreach {$roleHash[$_.roleId]=$_.name}

#always need to get a service instance. This is the root of the inventory; created by vSphere.
$serviceInstance = get-view ServiceInstance

# We get the root folder of the inventory tree and traverse the vCenter hierarchy from here.
$rootFolder = get-view -property Name $serviceInstance.Content.rootFolder

# This is where the magic happens.
GetInventoryItem $rootFolder.MoRef ""
ExportSettings
ExportRoles


$currentPath = Resolve-Path .
$xml.Save($currentPath.Path + "\" + $outputFile);

# Must disconnect from the vCenter server.
Disconnect-VIServer -Server $vCenter -Confirm:$false


# XML Format
# <item>
#	<name></name>
#	<path></path>
#	<type></type>
#	<childType></childType>
#  	<permissions>
#		<permission>
#			<role></role>
#			<propagate></propagate>
#			<principal></principal>
#			<user></user>
#		</permission>
#	</permissions>
# </item>
# EOF ----------------------------------------------------------------------------------------------
