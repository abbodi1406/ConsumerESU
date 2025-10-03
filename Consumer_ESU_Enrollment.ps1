param (
    [Parameter()]
    [switch]
    $Online,
    [Parameter()]
    [switch]
    $Store,
    [Parameter()]
    [switch]
    $Local,
    [Parameter()]
    [switch]
    $License,
    [Parameter()]
    [switch]
    $Remove,
    [Parameter()]
    [switch]
    $Proceed
)

[bool]$bDefault = $true
[bool]$bMsAccountUser  = $Online.IsPresent
[bool]$bMsAccountStore = $Store.IsPresent
[bool]$bLocalAccount   = $Local.IsPresent
[bool]$bAcquireLicense = $License.IsPresent
[bool]$bRemoveLicense = $Remove.IsPresent
[bool]$bProceed = $Proceed.IsPresent
if ($bMsAccountUser) {
	$bDefault = $false
	$bMsAccountStore = $false
	$bLocalAccount = $false
	$bAcquireLicense = $false
}
if ($bMsAccountStore) {
	$bDefault = $false
	$bMsAccountUser = $false
	$bLocalAccount = $false
	$bAcquireLicense = $false
}
if ($bLocalAccount) {
	$bDefault = $false
	$bMsAccountUser = $false
	$bMsAccountStore = $false
	$bAcquireLicense = $false
}
if ($bAcquireLicense) {
	$bDefault = $false
	$bMsAccountUser = $false
	$bMsAccountStore = $false
	$bLocalAccount = $false
}
if ($bRemoveLicense) {
	$bDefault = $false
	$bMsAccountUser = $false
	$bMsAccountStore = $false
	$bLocalAccount = $false
	$bAcquireLicense = $false
}

[bool]$cmdps = $MyInvocation.InvocationName -EQ "&"

function CONOUT($strObj)
{
	Out-Host -Input $strObj
}

function ExitScript($ExitCode = 0)
{
	if (!$psISE -And $cmdps) {
		Read-Host "`r`nPress Enter to exit" | Out-Null
	}
	Exit $ExitCode
}

if ($ExecutionContext.SessionState.LanguageMode.value__ -NE 0) {
	CONOUT "==== ERROR ====`r`n"
	CONOUT "Windows PowerShell is not running in Full Language Mode."
	ExitScript 1
}

if (-Not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
	CONOUT "==== ERROR ====`r`n"
	CONOUT "Windows PowerShell is not running as administrator."
	ExitScript 1
}

$SysPath = "$env:SystemRoot\System32"
if (Test-Path "$env:SystemRoot\Sysnative\reg.exe") {
	$SysPath = "$env:SystemRoot\Sysnative"
}

if (!(Test-Path "$SysPath\ConsumerESUMgr.dll")) {
	CONOUT "==== ERROR ====`r`n"
	CONOUT "ConsumerESUMgr.dll is not detected."
	CONOUT "Make sure to install update 2025-07 KB5061087 (19045.6036) or later."
	ExitScript 1
}

#region Globals
$eeStatus = @{
	0 = "Unknown";
	1 = "Ineligible";
	2 = "Eligible";
	3 = "DeviceEnrolled";
	4 = "ReEnrollReq";
	5 = "MSAEnrolled";
	6 = "ConsumerESUInactive";
	7 = "CommercialMigratedDevice";
	8 = "LoginWithPrimaryAccountToEnroll";
	9 = "LoginWithPrimaryAccountToCompletePreOrder";
	10 = "ComingSoon";
	11 = "EEAFreeMSAEnrolled";
	12 = "EEAPaidMSAEnrolled";
	13 = "WarnInactiveMSA";
	14 = "ReEnrollReqInactiveMSA";
}
$eeResult = @{
	1 = "SUCCESS";
	2 = "CONSUMER_ESU_PROGRAM_NOT_ACTIVE";
	3 = "NON_CONSUMER_DEVICE";
	4 = "COMMERCIAL_DEVICE";
	5 = "NON_ADMIN";
	6 = "CHILD_ACCOUNT";
	7 = "REGION_IN_EMBARGOED_COUNTRY";
	8 = "AZURE_DEVICE";
	9 = "COMMERCIAL_MIGRATED_DEVICE";
	10 = "LOGIN_WITH_PRIMARY_ACCOUNT_TO_COMPLETE_PREORDER";
	11 = "CONSUMER_ESU_FEATURE_DISABLED";
	12 = "KEY_BASED_ESU";
	13 = "EEA_REGION_POLICY_ENABLED";
	14 = "WARN_INACTIVE_MSA";
	15 = "REENROLL_REQ_INACTIVE_MSA";
	100 = "UNKNOWN_ERROR";
	101 = "CONSUMER_ESU_PROGRAM_ACTIVE_CHECK_FAILED";
	102 = "LICENSE_CHECK_FAILED";
	103 = "CONSUMER_DEVICE_CHECK_FAILED";
	104 = "COMMERCIAL_DEVICE_CHECK_FAILED";
	105 = "ADMIN_CHECK_FAILED";
	106 = "CHILD_ACCOUNT_CHECK_FAILED";
	107 = "ENTITLEMENT_CHECK_FAILED";
	108 = "ELIGIBILITY_EVALUATION_FAILED";
	109 = "AZURE_DEVICE_CHECK_FAILED";
	110 = "COMMERCIAL_MIGRATED_DEVICE_CHECK_FAILED";
	111 = "EMBARGOED_REGION_CHECK_FAILED";
	112 = "KEY_BASED_ESU_CHECK_FAILED";
	113 = "FREE_MSA_ELIGIBILITY_CHECK_FAILED";
}

$fKey10 = 'HKLM:\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides'
$fKey08 = 'HKLM:\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\8'
$TN = "ReconcileFeatures"; $TP = "\Microsoft\Windows\Flighting\FeatureConfig\"
$svc = 'DiagTrack'
$enablesvc = $false
try {$obj = Get-Service $svc -EA 1; $enablesvc = ($obj.StartType.value__ -eq 4)} catch {}
$featureESU = $false

$gKey = "HKCU:\Control Panel\International\Geo"
$rKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Control Panel\DeviceRegion"
$GeoId = (Get-ItemProperty $gKey "Nation" -EA 0).Nation
$GeoCN = (Get-ItemProperty $gKey "Name" -EA 0).Name
if ($null -eq $GeoCN) {try {$GeoCN = [Windows.System.UserProfile.GlobalizationPreferences,Windows,ContentType=WindowsRuntime]::HomeGeographicRegion} catch {}}
$jPath = "$SysPath\IntegratedServicesRegionPolicySet.json"
$DMA_SSO = $false
if (Test-Path $jPath) {
	$jData = Get-Content $jPath | ConvertFrom-Json
	$jList = ($jData.policies | where {$_.guid.Contains("1d290cdb-499c-4d42-938a-9b8dceffe998")}).conditions.region.disabled
	$DMA_SSO = $jList -contains $GeoCN
}

function NativeMethods
{
	$t = [AppDomain]::CurrentDomain.DefineDynamicAssembly((Get-Random), 1).DefineDynamicModule((Get-Random), $False).DefineType((Get-Random))
	$t.DefinePInvokeMethod('EnrollUsingBackupV1', 'consumeresumgr.dll', 22, 1, [Int32], @([Boolean].MakeByRefType(), [String], [Int32]), 1, 3).SetImplementationFlags(128)
	$t.DefinePInvokeMethod('GetESUEligibilityStatusV1', 'consumeresumgr.dll', 22, 1, [Int32], @([UInt32].MakeByRefType(), [UInt32].MakeByRefType(), [String], [Int32]), 1, 3).SetImplementationFlags(128)
	$t.DefinePInvokeMethod('CoSetProxyBlanket', 'ole32.dll', 22, 1, [Int32], @([IntPtr], [UInt32], [UInt32], [UInt32], [UInt32], [UInt32], [IntPtr], [UInt32]), 1, 3).SetImplementationFlags(128)
	$t.DefinePInvokeMethod('RtlQueryFeatureConfiguration', 'ntdll.dll', 22, 1, [Int32], @([UInt32], [UInt32], [UInt64].MakeByRefType(), [UInt32[]]), 1, 3).SetImplementationFlags(128)
	$t.DefinePInvokeMethod('RtlQueryFeatureConfigurationChangeStamp', 'ntdll.dll', 22, 1, [UInt64], @(), 1, 3).SetImplementationFlags(128)
	$t.DefinePInvokeMethod('RtlSetFeatureConfigurations', 'ntdll.dll', 22, 1, [Int32], @([UInt64].MakeByRefType(), [UInt32], [Byte[]], [Int32]), 1, 3).SetImplementationFlags(128)
	$Win32 = $t.CreateType()
}
#endregion

#region COM
function ComMethods
{
	$Marshal = [System.Runtime.InteropServices.Marshal]
	$CAB = [System.Reflection.Emit.CustomAttributeBuilder]
	$Module = [AppDomain]::CurrentDomain.DefineDynamicAssembly((Get-Random), 1).DefineDynamicModule((Get-Random), $False)

	$ICom = $Module.DefineType('LicenseManager.IApplicationLicenseManager', 'Public, Interface, Abstract, Import')
	$ICom.SetCustomAttribute($CAB::new([System.Runtime.InteropServices.ComImportAttribute].GetConstructor(@()), @()))
	$ICom.SetCustomAttribute($CAB::new([System.Runtime.InteropServices.GuidAttribute].GetConstructor(@([String])), @('90E2000C-B946-42FA-892F-94506F30CA4F')))
	$ICom.SetCustomAttribute($CAB::new([System.Runtime.InteropServices.InterfaceTypeAttribute].GetConstructor(@([Int16])), @([Int16]1)))
	[void]$ICom.DefineMethod('EnsureLicenseForApplicationDeployment', 'Public, Virtual, HideBySig, NewSlot, Abstract', 'Standard, HasThis', [Int32], @([String], [String], [String]))
	[void]$ICom.DefineMethod('RemoveLicensesForInstalledPackage', 1478, 33, [Int32], @([String], [UInt32]))
	$IALM = $ICom.CreateType()

	$ICom = $Module.DefineType('LicenseManager.IOperatingSystemLicenseManager', 4257)
	$ICom.SetCustomAttribute($CAB::new([System.Runtime.InteropServices.ComImportAttribute].GetConstructor(@()), @()))
	$ICom.SetCustomAttribute($CAB::new([System.Runtime.InteropServices.GuidAttribute].GetConstructor(@([String])), @('FA4A3CD4-E3F0-4875-9C69-CAD5423D05F4')))
	$ICom.SetCustomAttribute($CAB::new([System.Runtime.InteropServices.InterfaceTypeAttribute].GetConstructor(@([Int16])), @([Int16]1)))
	[void]$ICom.DefineMethod('ActivateLicenseForContent', 1478, 33, [Int32], @([String], [IntPtr].MakeByRefType()))
	$IOLM = $ICom.CreateType()
}

function DoAcquireLicense
{
	try {
		. ComMethods
		$ComObj = [Activator]::CreateInstance([Type]::GetTypeFromCLSID("22F5B1DF-7D7A-4D21-97F8-C21AEFBA859C"))
	} catch {
		return $FALSE
	}

	$pProxy = $Marshal::GetComInterfaceForObject($ComObj, $IALM)
	$hRet = $Win32::CoSetProxyBlanket($pProxy, 0xFFFFFFFFL, 0xFFFFFFFFL, 0, 0, 3, 0, 0x40)
	if ($hRet -ne 0) {return $FALSE}
	$parameters = 'b58e6308-bb55-e064-03ec-f6a5b029056e', $null, $null
	$hRet = $IALM.GetMethod("EnsureLicenseForApplicationDeployment").Invoke($ComObj, $parameters)
	if ($hRet -ne 0) {return $FALSE}

	$pProxy = $Marshal::GetComInterfaceForObject($ComObj, $IOLM)
	$hRet = $Win32::CoSetProxyBlanket($pProxy, [UInt32]::MaxValue, [UInt32]::MaxValue, 0, 0, 3, [IntPtr]::Zero, 0x40)
	if ($hRet -ne 0) {return $FALSE}
	$parameters = 'b58e6308-bb55-e064-03ec-f6a5b029056e', $null
	$hRet = $IOLM.GetMethod("ActivateLicenseForContent").Invoke($ComObj, $parameters)
	if ($hRet -ne 0) {return $FALSE}

	return $TRUE
}

function DoRemoveLicense
{
	try {
		. ComMethods
		$ComObj = [Activator]::CreateInstance([Type]::GetTypeFromCLSID("22F5B1DF-7D7A-4D21-97F8-C21AEFBA859C"))
	} catch {
		return $FALSE
	}

	$pProxy = $Marshal::GetComInterfaceForObject($ComObj, $IALM)
	$hRet = $Win32::CoSetProxyBlanket($pProxy, 0xFFFFFFFFL, 0xFFFFFFFFL, 0, 0, 3, 0, 0x40)
	if ($hRet -ne 0) {return $FALSE}
	$parameters = 'Microsoft.Windows10ConsumerExtendedSecurityUpdates_1.0.0.0_neutral_~_8wekyb3d8bbwe', [UInt32]3
	try {
		$hRet = $IALM.GetMethod("RemoveLicensesForInstalledPackage").Invoke($ComObj, $parameters)
		if ($hRet -ne 0) {return $FALSE}
	} catch {
		$host.UI.WriteLine('Red', 'Black', $_.Exception.Message + $_.ErrorDetails.Message)
		return $FALSE
	}

	return $TRUE
}
#endregion

#region WinRT
# https://superuser.com/a/1293303/380318 - https://fleexlab.blogspot.com/2018/02/using-winrts-iasyncoperation-in.html
Add-Type -AssemblyName System.Runtime.WindowsRuntime | Out-Null
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | ? { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function AwaitOperation($WinRtTask, $ResultType)
{
  $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
  $netTask = $asTask.Invoke($null, @($WinRtTask))
  $netTask.Wait(-1) | Out-Null
  $netTask.Result
}

function TokenMsAccountUser
{
	$provider = AwaitOperation ([Windows.Security.Authentication.Web.Core.WebAuthenticationCoreManager,Windows,ContentType=WindowsRuntime]::FindAccountProviderAsync("https://login.windows.local", "consumers")) ([Windows.Security.Credentials.WebAccountProvider,Windows,ContentType=WindowsRuntime])
	if ($null -eq $provider) {return $null}
	$request = [Windows.Security.Authentication.Web.Core.WebTokenRequest,Windows,ContentType=WindowsRuntime]::new($provider, "service::www.microsoft.com::MBI_SSL", "d122d5c5-5240-4164-b88c-986b5f1cf7f9", 0)
	if ($null -eq $request) {return $null}
	$result = AwaitOperation ([Windows.Security.Authentication.Web.Core.WebAuthenticationCoreManager,Windows,ContentType=WindowsRuntime]::GetTokenSilentlyAsync($request)) ([Windows.Security.Authentication.Web.Core.WebTokenRequestResult,Windows,ContentType=WindowsRuntime])
	if ($null -eq $result -Or $result.ResponseStatus -ne 0) {return $null}
	CONOUT "Obtained token for Microsoft user account"
	return $result.ResponseData[0].Token
}

function TokenMsAccountStore
{
	$id = $null
	$id = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Store" "PrimaryWebAccountId" -ErrorAction SilentlyContinue).PrimaryWebAccountId
	if ($null -eq $id) {$id = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Store\CurrentIdentity" "PrimaryWebAccountId" -ErrorAction SilentlyContinue).PrimaryWebAccountId}
	if ($null -eq $id) {return $null}
	$provider = AwaitOperation ([Windows.Security.Authentication.Web.Core.WebAuthenticationCoreManager,Windows,ContentType=WindowsRuntime]::FindAccountProviderAsync("https://login.microsoft.com", "consumers")) ([Windows.Security.Credentials.WebAccountProvider,Windows,ContentType=WindowsRuntime])
	if ($null -eq $provider) {return $null}
	$account = AwaitOperation ([Windows.Security.Authentication.Web.Core.WebAuthenticationCoreManager,Windows,ContentType=WindowsRuntime]::FindAccountAsync($provider, $id)) ([Windows.Security.Credentials.WebAccount,Windows,ContentType=WindowsRuntime])
	if ($null -eq $account) {return $null}
	$request = [Windows.Security.Authentication.Web.Core.WebTokenRequest,Windows,ContentType=WindowsRuntime]::new($provider, "service::www.microsoft.com::MBI_SSL", "d122d5c5-5240-4164-b88c-986b5f1cf7f9", 0)
	if ($null -eq $request) {return $null}
	$result = AwaitOperation ([Windows.Security.Authentication.Web.Core.WebAuthenticationCoreManager]::GetTokenSilentlyAsync($request, $account)) ([Windows.Security.Authentication.Web.Core.WebTokenRequestResult,Windows,ContentType=WindowsRuntime])
	if ($null -eq $result -Or $result.ResponseStatus -ne 0) {return $null}
	CONOUT "Obtained token for Microsoft store account"
	return $result.ResponseData[0].Token
}

function TokenLocalAccount
{
	[Windows.Security.Authentication.OnlineId.OnlineIdSystemAuthenticatorForUser,Windows,ContentType=WindowsRuntime] | Out-Null
	$auth = [Windows.Security.Authentication.OnlineId.OnlineIdSystemAuthenticator]::Default
	if ($null -eq $auth) {return $null}
	$auth.ApplicationId = [Guid]"D122D5C5-5240-4164-B88C-986B5F1CF7F9"
	$request = [Windows.Security.Authentication.OnlineId.OnlineIdServiceTicketRequest,Windows,ContentType=WindowsRuntime]::new("www.microsoft.com", "MBI_SSL")
	if ($null -eq $request) {return $null}
	$result = AwaitOperation ($auth.GetTicketAsync($request)) ([Windows.Security.Authentication.OnlineId.OnlineIdSystemTicketResult,Windows,ContentType=WindowsRuntime])
	if ($null -eq $result -Or $result.Status -ne 0) {return $null}
	CONOUT "Obtained token for Local user account"
	return $result.Identity.Ticket.Value
}

function ObtainToken
{
	CONOUT "`nObtain MSA Token ..."
	$msaToken = $null
	if ($null -eq $msaToken -And ($bDefault -Or $bMsAccountUser)) {
		$msaToken = TokenMsAccountUser
	}
	if ($null -eq $msaToken -And ($bDefault -Or $bMsAccountStore)) {
		$msaToken = TokenMsAccountStore
	}
	if ($null -eq $msaToken -And ($bDefault -Or $bLocalAccount)) {
		$msaToken = TokenLocalAccount
	}
	if ($null -eq $msaToken) {
		CONOUT "Operation Failed."
	}
}
#endregion

#region FCon
function RevertService
{
	if ($enablesvc) {
		try {Set-Service $svc -StartupType Disabled -EA 1} catch {}
		try {Stop-Service $svc -Force -Confirm:$false -EA 1} catch {}
	}
}

function RunService
{
	if ($enablesvc) {
		try {Set-Service $svc -StartupType Automatic -EA 1} catch {}
		try {Start-Service $svc -EA 1} catch {}
	} else {
		try {Start-Service $svc -EA 1} catch {}
	}
}

function RunTask
{
	try {$task = Get-ScheduledTask $TN $TP -ErrorAction Stop} catch {return}
	$null = Enable-ScheduledTask $TN $TP
	Start-ScheduledTask $TN $TP; while ((Get-ScheduledTask $TN $TP).State.value__ -eq 4) {start-sleep -sec 1}
}

function SetConfig($fID, $fState, $fReg)
{
	if ($fState -eq 2) {
		$fPriority = 10
		if ($null -eq (Get-ItemProperty $fKey10 -EA 0)) {$null = New-Item $fKey10 -Force -EA 0}
		$null = New-ItemProperty $fKey10 $fReg -Value $fState -Type DWord -Force -EA 0
	} else {
		$fPriority = 8
		if ($null -eq (Get-ItemProperty $fKey08 -EA 0)) {$null = New-Item $fKey08 -Force -EA 0}
		$fKeySub = $fKey08 + '\' + $fReg
		$null = New-Item $fKeySub -Force -EA 0
		$null = New-ItemProperty $fKeySub 'EnabledState' -Value $fState -Type DWord -Force -EA 0
		$null = New-ItemProperty $fKeySub 'EnabledStateOptions' -Value 0 -Type DWord -Force -EA 0
		if ($null -ne (Get-ItemProperty $fKey10 $fReg -EA 0)) {$null = Remove-ItemProperty $fKey10 $fReg -Force -EA 0}
	}

	RunService
	RunTask

	[byte[]]$fcon = [BitConverter]::GetBytes([UInt32]$fID) + [BitConverter]::GetBytes($fPriority) + [BitConverter]::GetBytes($fState) + [BitConverter]::GetBytes(0) + [BitConverter]::GetBytes(0) + [BitConverter]::GetBytes(0) + [BitConverter]::GetBytes(0) + [BitConverter]::GetBytes(1)
	try {[UInt64]$fccs = $Win32::RtlQueryFeatureConfigurationChangeStamp()} catch {[UInt64]$fccs = 0}
	try {
		$nRet = $Win32::RtlSetFeatureConfigurations([ref]$fccs, 1, $fcon, 1)
		if ($nRet -lt 0) {
			CONOUT ("Operation Failed: 0x" + ($nRet + 0x100000000L).ToString("X"))
			return
		}
	} catch {
		$host.UI.WriteLine('Red', 'Black', $_.Exception.Message + $_.ErrorDetails.Message)
		return
	}

	RunTask
	return
}

function QueryConfig($fID)
{
	try {
		$fInfo = [UInt32[]]::new(3)
		$nRet = $Win32::RtlQueryFeatureConfiguration([UInt32]$fID, 1, [ref]$null, $fInfo)
		if ($nRet -eq 0) {
			return (($fInfo[1] -band 0x30) -shr 4) -eq 2
		} else {
			return $FALSE
		}
	} catch {
		return $FALSE
	}
}
#endregion

#region EsuMgr
function PrintEligibility($esuStatus, $esuResult)
{
	$showStatus = ("Unknown", $eeStatus[$esuStatus])[($null -ne $eeStatus[$esuStatus])]
	CONOUT ("Eligibility Status: {0}" -f $showStatus)
	$showResult = ("UNKNOWN_RESULT", $eeResult[$esuResult])[($null -ne $eeResult[$esuResult])]
	CONOUT ("Eligibility Result: {0}" -f $showResult)
}

function CheckEligibility
{
	CONOUT "`nEvaluate ESU Eligibility state ..."
	& $SysPath\cmd.exe '/c' $SysPath\ClipESUConsumer.exe -evaluateEligibility
	$esuStatus = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows\ConsumerESU" "ESUEligibility" -ErrorAction SilentlyContinue).ESUEligibility
	$esuResult = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows\ConsumerESU" "ESUEligibilityResult" -ErrorAction SilentlyContinue).ESUEligibilityResult
	if ($null -eq $esuStatus -Or $null -eq $esuResult) {
		CONOUT "Operation Failed."
		return
	}
	PrintEligibility $esuStatus $esuResult
}

function GetEligibility
{
	CONOUT "`nGet ESU Eligibility state ..."
	$esuStatus = 0
	$esuResult = 11
	try {
		$hRet = $Win32::GetESUEligibilityStatusV1([ref]$esuStatus, [ref]$esuResult, $msaToken, $msaToken.Length)
	} catch {
		$host.UI.WriteLine('Red', 'Black', $_.Exception.Message + $_.ErrorDetails.Message)
		return
	}
	if ($hRet -ne 0) {
		CONOUT ("Operation Failed: 0x" + ($hRet + 0x100000000L).ToString("X"))
		return
	}
	PrintEligibility $esuStatus $esuResult
}

function DoEnroll
{
	CONOUT "`nRun Consumer ESU Enrollment ..."
	$isEnrolled = $false
	try {
		$hRet = $Win32::EnrollUsingBackupV1([ref]$isEnrolled, $msaToken, $msaToken.Length)
	} catch {
		$host.UI.WriteLine('Red', 'Black', $_.Exception.Message + $_.ErrorDetails.Message)
		return $FALSE
	}
	if ($hRet -ne 0) {
		CONOUT ("Operation Failed: 0x" + ($hRet + 0x100000000L).ToString("X"))
		return $FALSE
	}
	CONOUT ("IsEnrolled result: " + ("False", "True")[$isEnrolled])
	return $TRUE
}

function RunAcquireLicense
{
	CONOUT "`nAcquire Consumer ESU License regardless enrollment ..."
	$bRet = DoAcquireLicense
	CONOUT ("Operation result: " + ("Failure", "Success")[$bRet])
	CheckEligibility
	Exit !$bRet
}

function RunRemoveLicense
{
	CONOUT "`nRemove Consumer ESU License if exists ..."
	$bRet = DoRemoveLicense
	CONOUT ("Operation result: " + ("Failure", "Success")[$bRet])
	CheckEligibility
	Exit !$bRet
}
#endregion

#region Unlicense
if ($bRemoveLicense) {
	. NativeMethods
	RunRemoveLicense
}
#endregion

#region Features
. NativeMethods
$featureESU = QueryConfig 57517687
if (!$featureESU) {
	CONOUT "`nEnable Consumer ESU feature ..."
	SetConfig 57517687 2 "4011992206"
}
if ($DMA_SSO) {
	CONOUT "`nDisable EEA_REGION_POLICY_CHECK features ..."
	SetConfig 58992578 1 "2216818319"
	SetConfig 58755790 1 "2642149007"
	SetConfig 59064570 1 "4109366415"
}
if ($enablesvc) {
	RevertService
}

try {
	$hRet = $Win32::GetESUEligibilityStatusV1([ref]$null, [ref]$null, [NullString]::Value, 0)
} catch {
	$host.UI.WriteLine('Red', 'Black', $_.Exception.Message + $_.ErrorDetails.Message)
	ExitScript 1
}
if ($hRet -eq 0x80080002) {
	CONOUT "==== ERROR ====`r`n"
	CONOUT "Consumer ESU feature is still not enabled: E_CONSUMER_ESU_FEATURE_DISABLED"
	CONOUT "Close this console session and run the script again to take effect."
	ExitScript 1
}
#endregion

#region Main
if ($bAcquireLicense) {
	RunAcquireLicense
}

. CheckEligibility
$supported = $false
if ($null -ne $esuStatus) {
	$supported = ($esuStatus -ge 2 -And $esuStatus -le 5) -Or ($esuStatus -ge 11 -And $esuStatus -le 14) -Or (($esuStatus -eq 1 -Or $esuStatus -eq 10) -And ($esuResult -ge 13 -And $esuResult -le 15))
}
if (!$supported) {
	CONOUT "`nEligibility status is not supported for enrollment."
	CONOUT "Run the script with -License parameter to force acquire license."
	ExitScript 1
}
if ($esuResult -eq 1 -And ($esuStatus -eq 3 -Or $esuStatus -eq 11 -Or $esuStatus -eq 12) -And !$bProceed) {
	CONOUT "`nYour PC is already enrolled for Consumer ESU."
	CONOUT "No need to proceed."
	ExitScript 0
}

if ($DMA_SSO) {
	$null = New-ItemProperty $gKey "Nation" -Value 244 -Type String -Force -EA 0
	if ($null -ne (Get-ItemProperty $rKey -EA 0)) {$null = New-ItemProperty $rKey "DeviceRegion" -Value 244 -Type DWord -Force -EA 0}
}
. ObtainToken
if ($DMA_SSO) {
	$null = New-ItemProperty $gKey "Nation" -Value $GeoId -Type String -Force -EA 0
	if ($null -ne (Get-ItemProperty $rKey -EA 0)) {$null = New-ItemProperty $rKey "DeviceRegion" -Value $GeoId -Type DWord -Force -EA 0}
}

if ($null -eq $msaToken) {
	if (!$bDefault) {
		CONOUT "`nRun the script without parameters to obtain other tokens or force acquire license."
		ExitScript 1
	}
	RunAcquireLicense
}

$eRet = DoEnroll
if (!$eRet) {
	CheckEligibility
	Exit !$eRet
}
# GetEligibility
CheckEligibility
ExitScript 0
#endregion

