[CmdletBinding()]


# Modify the $VCCISOURI with the latest link 

Param(
    [string] $BucketName,
    [string] $VeeamUserName,    
    [string] $DBPass
 )


#Variables
$VMName = $env:computername
$GuestOSName = $env:computername
$url = "https://download2.veeam.com/VBR/v11/VeeamBackup&Replication_11.0.0.837_20210220.iso"
$output = "C:\Packages\Plugins\Microsoft.Compute.CustomScriptExtension\VeeamBackupReplication.iso"
$source = "C:\Packages\Plugins\Microsoft.Compute.CustomScriptExtension"
$patchurl = "https://download2.veeam.com/VeeamKB/4126/VeeamBackup&Replication_11.0.0.837_20210525.zip"
$patchoutput = "C:\Packages\Plugins\Microsoft.Compute.CustomScriptExtension\VeeamBRPatch.zip"
$policyurl = "https://raw.githubusercontent.com/maciejng/awspowershellscripts/main/VeeamPolicy.json"
$policyoutput = "C:\Packages\Plugins\Microsoft.Compute.CustomScriptExtension\VeeamPolicy.json"


#Create Veeam User
Start-Sleep -s 60
$USERNAME = "veeam"
$PASSWORD = $DBPass


$group = "Administrators"

$adsi = [ADSI]"WinNT://$env:COMPUTERNAME"
$existing = $adsi.Children | where {$_.SchemaClassName -eq 'user' -and $_.Name -eq $USERNAME }

if ($existing -eq $null) {

    Write-Host "Creating new local user $USERNAME."
    & NET USER $USERNAME $PASSWORD /add /y /expires:never
    
    Write-Host "Adding local user $USERNAME to $group."
    & NET LOCALGROUP $group $USERNAME /add

}
else {
    Write-Host "Setting password for existing local user $USERNAME."
    $existing.SetPassword($PASSWORD)
}

Write-Host "Ensuring password for $USERNAME never expires."
& WMIC USERACCOUNT WHERE "Name='$USERNAME'" SET PasswordExpires=FALSE

#Create install directory
New-Item -itemtype directory -path $source

#Get VCC isook
(New-Object System.Net.WebClient).DownloadFile($url, $output)
#Write-Output "Time taken: $((Get-Date).Subtract($start_time).Seconds) second(s)"

#Initialize Data Disks
Get-Disk | ` 
Where partitionstyle -eq 'raw' | ` 
Initialize-Disk -PartitionStyle GPT -PassThru | ` 
New-Partition -AssignDriveLetter -UseMaximumSize | ` 
Format-Volume -FileSystem ReFS -NewFileSystemLabel "datadisk" -Confirm:$false




$iso = Get-ChildItem -Path "C:\Packages\Plugins\Microsoft.Compute.CustomScriptExtension\VeeamBackupReplication.iso"
Mount-DiskImage $iso.FullName

Write-Output -InputObject "[$($VMName)]:: Installing Veeam Unattended"
  
$setup = $(Get-DiskImage -ImagePath $iso.FullName | Get-Volume).DriveLetter +':' 
$setup


$source = $setup


$Driveletter = get-wmiobject -class "Win32_Volume" -namespace "root\cimv2" | where-object {$_.DriveLetter -like "D*"}
$VeeamDrive = $DriveLetter.DriveLetter


  #region: Variables
$fulluser = "$($GuestOSName)\$($USERNAME)"
$secpasswd = ConvertTo-SecureString $PASSWORD -AsPlainText -Force
$mycreds = New-Object System.Management.Automation.PSCredential($fulluser, $secpasswd)
$CatalogPath = "$($VeeamDrive)\VbrCatalog"
$vPowerPath = "$($VeeamDrive)\vPowerNfs"

 #region: logdir
 $logdir = "$($VeeamDrive)\logdir"
 $trash = New-Item -ItemType Directory -path $logdir  -ErrorAction SilentlyContinue
 #endregion

  ## Global Prerequirements
  Write-Host "Installing Global Prerequirements ..." -ForegroundColor Yellow
  ### 2012 System CLR Types
  Write-Host "    Installing 2012 System CLR Types ..." -ForegroundColor Yellow
  $MSIArguments = @(
      "/i"
      "$source\Redistr\x64\SQLSysClrTypes.msi"
      "/qn"
      "/norestart"
      "/L*v"
      "$logdir\01_CLR.txt"
  )
  Start-Process "msiexec.exe" -ArgumentList $MSIArguments -Wait -NoNewWindow

  if (Select-String -path "$logdir\01_CLR.txt" -pattern "Installation success or error status: 0.") {
    Write-Host "    Setup OK" -ForegroundColor Green
    }
    else {
        throw "Setup Failed"
        }

  ### 2012 Shared management objects
  Write-Host "    Installing 2012 Shared management objects ..." -ForegroundColor Yellow
  $MSIArguments = @(
      "/i"
      "$source\Redistr\x64\SharedManagementObjects.msi"
      "/qn"
      "/norestart"
      "/L*v"
      "$logdir\02_Shared.txt"
  )
  Start-Process "msiexec.exe" -ArgumentList $MSIArguments -Wait -NoNewWindow

  if (Select-String -path "$logdir\02_Shared.txt" -pattern "Installation success or error status: 0.") {
      Write-Host "    Setup OK" -ForegroundColor Green
      }
      else {
          throw "Setup Failed"
          }
	  
### Microsoft Report Viewer
  Write-Host "    Microsoft Report Viewer ..." -ForegroundColor Yellow
  $MSIArguments = @(
      "/i"
      "$source\Redistr\ReportViewer.msi"
      "/qn"
      "/norestart"
      "/L*v"
      "$logdir\03_ReportViewer.txt"
  )
  Start-Process "msiexec.exe" -ArgumentList $MSIArguments -Wait -NoNewWindow

  if (Select-String -path "$logdir\03_ReportViewer.txt" -pattern "Installation success or error status: 0.") {
    Write-Host "    Setup OK" -ForegroundColor Green
    }
    else {
        throw "Setup Failed"
        }
	
  ### SQL Express
          ### Info: https://msdn.microsoft.com/en-us/library/ms144259.aspx
          Write-Host "    Installing SQL Express ..." -ForegroundColor Yellow
          $Arguments = "/HIDECONSOLE /Q /IACCEPTSQLSERVERLICENSETERMS /ACTION=install /FEATURES=SQLEngine,SNAC_SDK /INSTANCENAME=VEEAMSQL2016 /SQLSVCACCOUNT=`"NT AUTHORITY\SYSTEM`" /SQLSYSADMINACCOUNTS=`"$fulluser`" `"Builtin\Administrators`" /TCPENABLED=1 /NPENABLED=1 /UpdateEnabled=0"
          Start-Process "$source\Redistr\x64\SqlExpress\2016SP2\SQLEXPR_x64_ENU.exe" -ArgumentList $Arguments -Wait -NoNewWindow
  
  ## Veeam Backup & Replication
  Write-Host "Installing Veeam Backup & Replication ..." -ForegroundColor Yellow
  ### Backup Catalog
  Write-Host "    Installing Backup Catalog ..." -ForegroundColor Yellow
  $trash = New-Item -ItemType Directory -path $CatalogPath -ErrorAction SilentlyContinue
  $MSIArguments = @(
      "/i"
      "$source\Catalog\VeeamBackupCatalog64.msi"
      "/qn"
      "ACCEPT_THIRDPARTY_LICENSES=1"
      "/L*v"
      "$logdir\04_Catalog.txt"
      "VM_CATALOGPATH=$CatalogPath"
      "VBRC_SERVICE_USER=$fulluser"
      "VBRC_SERVICE_PASSWORD=$PASSWORD"
  )
  Start-Process "msiexec.exe" -ArgumentList $MSIArguments -Wait -NoNewWindow

  if (Select-String -path "$logdir\04_Catalog.txt" -pattern "Installation success or error status: 0.") {
      Write-Host "    Setup OK" -ForegroundColor Green
      }
      else {
          throw "Setup Failed"
          }


 ### Backup Server
 Write-Host "    Installing Backup Server ..." -ForegroundColor Yellow
 $trash = New-Item -ItemType Directory -path $vPowerPath -ErrorAction SilentlyContinue
 $MSIArguments = @(
     "/i"
     "$source\Backup\Server.x64.msi"
     "/qn"
     "ACCEPT_THIRDPARTY_LICENSES=1"
     "/L*v"
     "$logdir\05_Backup.txt"
     "ACCEPTEULA=YES"
     "VBR_SERVICE_USER=$fulluser"
     "VBR_SERVICE_PASSWORD=$PASSWORD"
     "PF_AD_NFSDATASTORE=$vPowerPath"
     "VBR_SQLSERVER_SERVER=$env:COMPUTERNAME\VEEAMSQL2016"
 )
 Start-Process "msiexec.exe" -ArgumentList $MSIArguments -Wait -NoNewWindow

 if (Select-String -path "$logdir\05_Backup.txt" -pattern "Installation success or error status: 0.") {
     Write-Host "    Setup OK" -ForegroundColor Green
     }
     else {
         throw "Setup Failed"
         }

 ### Backup Console
 Write-Host "    Installing Backup Console ..." -ForegroundColor Yellow
 $MSIArguments = @(
     "/i"
     "$source\Backup\Shell.x64.msi"
     "/qn"
     "/L*v"
     "$logdir\06_Console.txt"
     "ACCEPTEULA=YES"
     "ACCEPT_THIRDPARTY_LICENSES=1"
 )
 Start-Process "msiexec.exe" -ArgumentList $MSIArguments -Wait -NoNewWindow

 if (Select-String -path "$logdir\06_Console.txt" -pattern "Installation success or error status: 0.") {
     Write-Host "    Setup OK" -ForegroundColor Green
     }
     else {
         throw "Setup Failed"
         }



### Explorers
Write-Host " Installing Explorer For ActiveDirectory ..." -ForegroundColor Yellow
$MSIArguments = @(
"/i"
"$source\Explorers\VeeamExplorerForActiveDirectory.msi"
"/qn"
"/L*v"
"$logdir\07_ExplorerForActiveDirectory.txt"
"ACCEPT_THIRDPARTY_LICENSES=1"
"ACCEPT_EULA=1"
)
Start-Process "msiexec.exe" -ArgumentList $MSIArguments -Wait -NoNewWindow
if (Select-String -path "$logdir\07_ExplorerForActiveDirectory.txt" -pattern "Installation success or error status: 0.") {
Write-Host " Setup OK" -ForegroundColor Green
}
else {
throw "Setup Failed"
}



Write-Host " Installing Explorer For Exchange ..." -ForegroundColor Yellow
$MSIArguments = @(
"/i"
"$source\Explorers\VeeamExplorerForExchange.msi"
"/qn"
"/L*v"
"$logdir\08_VeeamExplorerForExchange.txt"
"ADDLOCAL=BR_EXCHANGEEXPLORER,PS_EXCHANGEEXPLORER"
"ACCEPT_THIRDPARTY_LICENSES=1"
"ACCEPT_EULA=1"
)
Start-Process "msiexec.exe" -ArgumentList $MSIArguments -Wait -NoNewWindow
if (Select-String -path "$logdir\08_VeeamExplorerForExchange.txt" -pattern "Installation success or error status: 0.") {
Write-Host " Setup OK" -ForegroundColor Green
}
else {
throw "Setup Failed"
}

Write-Host " Installing Explorer For SQL ..." -ForegroundColor Yellow
$MSIArguments = @(
"/i"
"$source\Explorers\VeeamExplorerForSQL.msi"
"/qn"
"/L*v"
"$logdir\09_VeeamExplorerForSQL.txt"
"ACCEPT_THIRDPARTY_LICENSES=1"
"ACCEPT_EULA=1"
)
Start-Process "msiexec.exe" -ArgumentList $MSIArguments -Wait -NoNewWindow
if (Select-String -path "$logdir\09_VeeamExplorerForSQL.txt" -pattern "Installation success or error status: 0.") {
Write-Host " Setup OK" -ForegroundColor Green
}
else {
throw "Setup Failed"
}

Write-Host " Installing Explorer For SharePoint ..." -ForegroundColor Yellow
$MSIArguments = @(
"/i"
"$source\Explorers\VeeamExplorerForSharePoint.msi"
"/qn"
"/L*v"
"$logdir\11_VeeamExplorerForSharePoint.txt"
"ADDLOCAL=BR_SHAREPOINTEXPLORER,PS_SHAREPOINTEXPLORER"
"ACCEPT_THIRDPARTY_LICENSES=1"
"ACCEPT_EULA=1"
)
Start-Process "msiexec.exe" -ArgumentList $MSIArguments -Wait -NoNewWindow
if (Select-String -path "$logdir\11_VeeamExplorerForSharePoint.txt" -pattern "Installation success or error status: 0.") {
Write-Host " Setup OK" -ForegroundColor Green
}
else {
throw "Setup Failed"
}


#Get Veeam Backup and Recovery Patch
Write-Host " Installing Veeam Backup and Restore Patch ..." -ForegroundColor Yellow
(New-Object System.Net.WebClient).DownloadFile($patchurl, $patchoutput)
Expand-Archive C:\Packages\Plugins\Microsoft.Compute.CustomScriptExtension\VeeamBRPatch.zip -DestinationPath C:\Packages\Plugins\Microsoft.Compute.CustomScriptExtension\ -Force
Start-Process -Wait -ArgumentList "/silent" -PassThru -FilePath "C:\Packages\Plugins\Microsoft.Compute.CustomScriptExtension\VeeamBackup&Replication_11.0.0.837_20210525.exe"
#Start-Process -Wait -ArgumentList "/silent" -PassThru -RedirectStandardOutput "$logdir\12_VeeamPatch.txt" -RedirectStandardError "$logdir\12_VeeamPatchErrors.txt" -FilePath "C:\Packages\Plugins\Microsoft.Compute.CustomScriptExtension\VeeamBackup&Replication_11.0.0.837_20210525.exe"
Write-Host " Setup OK" -ForegroundColor Green


#Create New IAM user for S3 bucket
(New-Object System.Net.WebClient).DownloadFile($policyurl, $policyoutput)
$keyatt = New-IAMAccessKey -UserName $VeeamUserName
$AccessKey = $keyatt.AccessKeyId
$SecurityKey = $keyatt.SecretAccessKey


$scriptblock= {
Connect-VBRServer
Add-VBRAmazonAccount -AccessKey $Using:AccessKey -SecretKey $Using:SecurityKey
$account = Get-VBRAmazonAccount -AccessKey $Using:AccessKey
$connect = Connect-VBRAmazonS3Service -Account $account -RegionType Global -ServiceType CapacityTier
#$region = Get-VBRAmazonS3Region -Connection $connection
$container = Get-VBRAmazonS3Bucket -Connection $connect -Name $Using:BucketName
New-VBRAmazonS3Folder -bucket $container -Connection $connect -Name "VeeamObject"
$folder1 = Get-VBRAmazonS3Folder -Bucket $container -Connection $connect -Name "VeeamObject"
Add-VBRAmazonS3Repository -AmazonS3Folder $folder1 -Connection $connect
}

$session = New-PSSession -cn $env:computername
 Invoke-Command -Session $session -ScriptBlock $scriptblock 
 Remove-PSSession -VMName $env:computername
