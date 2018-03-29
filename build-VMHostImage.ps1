<#
.SYNOPSIS
   Workflow automation for building a vSphere ESXi image (offline bundle and .iso)
.DESCRIPTION
    Workflow script to automate the building of a vSphere ESXi image.
    The script needs the parameters.ps1 file.
    It can be used for multiple 'projects'. Each project has the same folder structure.
    Folder structure when finished is like,
    .\
     build-VMHostImage.ps1
     parameters.ps1
     <image name>\
               vCenterFQDN.xml                        --- vCenter FQDN to download HA vib from
               Source\                                --- folder containing ESXi offline bundle as a source
               Vibs\                                  --- folder containing vibs to add to the new image
                   <vendor A>\
                           <vib offline bundles>.zip
                   <vendor B>\
                           <vib offline bundles>.zip
               Image\                                 --- output folder containing both offline bundle and .iso image file
                   <image name>.zip
                   <image name>.iso
                   added.txt                          --- list of vibs added to the source image
                   skipped.txt                        --- vibs that are skipped
                   viblist.txt                        --- list containing all vibs in the created image
                   excluded.txt                       --- list of VIBS that are excluded in created image

    When the script detects no folder structure beneath the <image name>, it will create one.
    Also, if there is no offline bundle in the source folder, the script will contact the online VMware repository 
    and shows a selection in a gridview of the images that can be used. 

.PARAMETER noHA
    [switch] Build the image without the HA vib from the vCenter

.PARAMETER useVMwareDepot
    [switch] use the VMware online repository for selecting a source image.
.EXAMPLE
    Build an ESXi image without the HA vib
    >build-vmhostimage.ps1 -noHA
.NOTES
    File Name          : build-VMHostImage.ps1
    Author             : B. Lievers
    Prerequisite       : PowerShell V2 over Vista and upper.
    Version            : 0.4
    License            : MIT License
    Copyright 2018 - Bart Lievers
#>
[CmdletBinding()]
Param(
    [Parameter(HelpMessage="[Boolean] Don't add the VMware HA vib")][switch]$noHA,
   [Parameter(Position=0,HelpMessage="[Boolean] Use the VMware online software Depot as source")] [switch]$useVMwareDepot
   )


Begin{
#Parameters
    $TS_start=Get-Date #-- get start time
    #-- get script parameters
	$scriptpath=(get-item (Split-Path -parent $MyInvocation.MyCommand.Definition)).fullname
	$scriptname=Split-Path -Leaf $MyInvocation.mycommand.path
    #-- load default parameter
    #-- Load Parameterfile
    if (!(test-path -Path $scriptpath\parameters.ps1 -IsValid)) {
        write-warning "parameters.ps1 not found. Script will exit."
        exit
    }
    $P = & $scriptpath\parameters.ps1
    if ($P.ProjectIMFoldersAreSiblings) {
        $scriptpath=split-path -Path $scriptpath -Parent
    }

    # Gather all supporting functions
    $Functions  = @(Get-ChildItem -Path ($scriptpath+"\"+$P.FunctionsSubFolder) -Filter *.ps1 -ErrorAction SilentlyContinue)

    # Dot source the functions
    ForEach ($File in @($Functions)) {
        Try {
            . $File.FullName
        } Catch {
            Write-Error -Message "Failed to import function $($File.FullName): $_"
        }       
    }

    #-- initialize variables
    $URLDepots=@()
    $VIBlist= @()


#region Functions

    function exit-script {
        <#
        .DESCRIPTION
            Clean up actions before we exit the script.
        #>
        [CmdletBinding()]
        Param()
        #-- disconnect vCenter connections (if there are any)
        if ((Get-Variable -Scope global -Name DefaultVIServers -ErrorAction SilentlyContinue ).value) {
            Disconnect-VIServer -server * -Confirm:$false
        }
        #-- clock time and say bye bye
        $ts_end=get-date
        write-host ("Runtime script: {0:hh}:{0:mm}:{0:ss}" -f ($ts_end- $TS_start)  )
        read-host "End script. bye bye ([Enter] to quit.)"
        exit
    }

    function check-folderStructure {
    <#
    .SYNOPSIS
        Check if folderstructure of image project is valid
    .DESCRIPTION
        Validation and/or repar folderstructure of image project 
        Returns $true if image or source folder isn't present
    #>
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)][string]$ProjectPath
    )
        #-- check if folderstructure is inplace, if not, create it.
        $isNoDir=$false
        if ((Test-Path -Path "$ProjectPath\image") -eq $false) {
            write-warning "Image folder is missing, creating folder."
            New-Item -ItemType Directory -Path "$ProjectPath\Image" | Out-Null
            $isnoDir = $isNoDir -or $true
        }
        if ((Test-Path -Path "$ProjectPath\Vibs") -eq $false) {
            write-warning "Vibs folder is missing, creating folder."
            New-Item -ItemType Directory -Path "$ProjectPath\Vibs"  | Out-Null
        }
        if ((Test-Path -Path "$ProjectPath\Source") -eq $false) {
            write-warning "Source (Offline Bundle) folder is missing, creating folder."
            New-Item -ItemType Directory -Path "$ProjectPath\Source"  | Out-Null
            $isnoDir = $isNoDir -or $true
        }
        return ($isNoDir)
    }

    Function check-ImageFolder {
    <#
    .SYNOPSIS
        Check if .ISO and Offline Bundle already exists in image Folder
    .DESCRIPTION
        Check if .ISO and Offline Bundle already exists in image Folder.
        If files exist, ask if they should be removed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)][string]$ProjectPath,
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)][string]$NewImName

    )

    $runExport=$false
    if (Get-ChildItem -Path ("$ProjectPath\image") | ?{$_.fullname -match "$NewIMName.zip|$NewImName.iso"}) {
        write-host "Unable to export to offline bundle and/or .iso, files already exist in image folder."
            do {
                #-- Ask if files can be removed.
                $answ=read-host "Would you like to remove the existing files ? [y/N] :  "
                switch -Regex ($answ)  {
                    "" {
                        #-- Geen input gegeven, dus gebruik default
                        $answ="N"}
                    "Y|y|j|J" {
                        #-- remove old files
                        $RunExport=$true
                        write-host "Removing existing offline bundle and .iso file in image folder."
                        Get-ChildItem -Path ("$ProjectPath\image") | ?{$_.fullname -match "$NewIMName.zip|$NewImName.iso"} | Remove-Item -Force
                        break
                        }
                    "[^yYjJnN]" {
                        #-- wrong input
                        Write-Warning "Invalid answer."
                        break
                        }
                }
            } while ($answ -inotmatch "y|Y|j|J|n|N")
    } else {
        $RunExport=$true
    }
    return $RunExport
    }

    Function Filter-VMwareDepot {
    <#
    .SYNOPSIS
        Returns a string to filter the VMware online software depot
    .DESCRIPTION
        Returns a string to filter the VMware online software depot
    #>
    [CmdletBinding()]
    param(
        [string]$version
    )

    $List=@()
    $row= "" | select Filter,Omschrijving,ID
    $row.Filter="ESXi-6.5.*-standard"
    $row.Omschrijving="vSphere host 6.5"
    $row.id="65"
    $list+=$row
    $row= "" | select Filter,Omschrijving,ID
    $row.Filter="ESXi-6.0.*-standard"
    $row.Omschrijving="vSphere host 6.0"
    $row.id="60"
    $list+=$row
    $row= "" | select Filter,Omschrijving,ID
    $row.Filter="ESXi-5.5.*-standard"
    $row.Omschrijving="vSphere host 5.5"
    $row.id="55"
    $list+=$row
    $row= "" | select Filter,Omschrijving,ID
    $row.Filter="ESXi-5.1.*-standard"
    $row.Omschrijving="vSphere host 5.1"
    $row.id="51"
    $list+=$row
    $row= "" | select Filter,Omschrijving,ID
    $row.Filter="ESXi-5.0.*-standard"
    $row.Omschrijving="vSphere host 5.0"
    $row.id="50"
    $list+=$row
    if ($version.Length -eq 0) {
        $answer=$list | select filter,Omschrijving | Out-GridView -PassThru -title "Selecteer ESXi versie."  | select -ExpandProperty  Filter
    } else {
        $answer=$list | ?{$_.id -eq $version} | select -ExpandProperty filter
    }
    return $answer
    }

    Function export-Images {
    <#
    .SYNOPSIS
        Export new image profile to offline bundle and .ISO file
    .DESCRIPTION
        Export new image profile to offline bundle and .ISO file to Image folder.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)][string]$ProjectPath,
        [parameter(Mandatory=$true,helpmessage="Profile image name to export.")][string]$NewIMName,
        [Parameter(helpmessage="child-folder to export image to.")][string]$exportFolderName="Image"
    )
        #-- export Image profile
        Export-EsxImageProfile -ImageProfile $NewIMName -FilePath "$ProjectPath\$exportFolderName\$NewIMName.iso" -ExportToIso
        Export-EsxImageProfile -ImageProfile $NewIMName -FilePath "$ProjectPath\$exportFolderName\$NewIMName.zip" -ExportToBundle
        #-- Report vibs to text file
        Get-EsxImageProfile -Name $NewIMName | select -ExpandProperty viblist | select  name, summary,vendor,version,creationdate | sort vendor,name |ft -autosize |out-string -Width 256 | Out-File $ProjectPath\$exportFolderName\viblist.txt
    }

    Function export-BaseImage {
    <#
    .SYNOPSIS
        Export base image profile as offline bundle to offline bundle folder
    .DESCRIPTION
        Export base image profile as offline bundle to offline bundle folder
        Is used when base image profile is selected from the VMware software depot
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)][string]$SourceIMName,
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)][string]$ProjectPath,
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)][string]$NewIMName
    )
        #--check if Base Offline Bundle already exists
        write-host "VMware Offline bundle $SourceIMName is being downloaded to the source folder." 
        $exportpath="$ProjectPath\Source\$SourceIMName.zip"
        $answer=$false
        if (Get-ChildItem -Path ("$ProjectPath\Source") | ?{$_.fullname -match "$SourceIMName.zip"}) {
            do {
                $answer=read-host "$SourceIMName already exists in .\source\ folder, do you want to replace it ? [y/N]"
                if ($answer.Length -eq 0) {$answer="N"}
                switch -Regex ($answer)  {
                    "Y|y|j|J" {
                        Remove-Item -Path $exportpath -Force
                        break
                        }
                    "[^yYjJnN]" {
                        #-- wrong input
                        Write-Warning "Invalid answer."
                        break
                        }
                }
            } while  ($answer -inotmatch " y|Y|j|J|n|N")
        }
        #-- Export Image profile to offline bundle in offline bundle folder
        if (($answer -imatch "j|J|y|Y") -or -not($answer)) {
      #      write-host "Image $SourceIMName wordt als offline bundle ge-exporteerd."
            Export-EsxImageProfile -ImageProfile $SourceIMName -FilePath $exportpath -ExportToBundle
        }
        return $exportpath
    }

    Function validate-vCenterFQDN {
    <#
    .SYNOPSIS
        Ask for and validate FQDN of vCenter
    .DESCRIPTION
        Ask for and validate FQDN of vCenter.
        When FQDN is valid, the script will add it to the software depots list, for downloading the HA vib.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)][string]$ProjectPath)

        $xml_FQDNvCenter="$ProjectPath\vCenterFQDN.xml"
        if (Test-Path -Path $xml_FQDNvCenter ) {
            $def_FQDNvCenter=Import-Clixml -Path $xml_FQDNvCenter
        } else {
            $def_FQDNvCenter = ""
        }
        [string]$FQDNvCenter=read-host ("What is the vCenter's FQDN to download the HA vib from ? ["+$def_FQDNvCenter+"]")
        do {
            $validFQDN=$false

            if (($FQDNvCenter.Length -eq 0) -and  ($def_FQDNvCenter.Length -eq 0)  ) {
                write-warning "Invalid FQDN for the vCenter."
            }
            if ($FQDNvCenter.Length -eq 0) {
                $FQDNvCenter = $def_FQDNvCenter
            }

            #-- test if vCenter is alive
            if ($FQDNvCenter.Length -eq 0) {
                $noHA=$true
            } elseif (-not(Test-Connection -ComputerName $FQDNvCenter -Count 1 -Quiet)) {
                Write-Warning "vCenter $FQDNvCenter doesn't respond."
                $FQDNvCenter=read-host "What is the vCenter's FQDN ? "
                if ($FQDNvCenter.Length -eq 0) {
                    #-- No input received, proceed without HA vib
                    $noHA=$true
                    write-host "No input received, HA vib will not be implemented."
                }
            } else {
                #-- vCenter FQDN is geldig
                $validFQDN=$true
                $FQDNvCenter | Export-Clixml -Path $ProjectPath\vCenterFQDN.xml -Force
            }
        } until ($noHA -or $validFQDN)
        return $noHA
    }

    Function get-ImageProject {
        $IMProjects=Get-ChildItem -Path $scriptpath -Filter IM-* -Directory
        if ($imProjects) {
            $IMProject= $IMprojects | Out-GridView -OutputMode Single -Title "Select an ESXi Image Project ([Cancel] to start a new project)" | select -ExpandProperty name
        } else {
            write-host "No subfolders found that start with (IM-*)."
            $imProject=$null
        }
        return $improject
    }

    Function get-ImageName {
    <#
    .SYNOPSIS
        Ask for the name of the .ISO and offline bundle files to create.
    .DESCRIPTION
        Ask for the name of the .ISO and offline bundle files to create.
        The foldername where this script is placed will be suggested as default.
    .PARAMETER noGuess
        Don't use the name of the working directory as the name for  the new image.
    #>
    [cmdletbinding()]
    Param(
        [string]$NewIMName=""
    )
    $answ=$null
    do {
        #-- validate image name
        if  ( ($answ)) {
   #         if (-not(validate-ImageName -ImageName $NewIMName -Explain)) {
   #             write-warning "Image naam is niet conform naam conventie."
   #         }
        }
        if ($newIMName.Length -gt 0) {
            Write-Host "Image name : " $NewIMName
            $answ=Read-Host "Is this correct ? [y/N]"
        }
        if ($answ.Length -eq 0) {$answ="N"} #-- default input
        if ($answ -imatch "n|N") {
            $NewIMName=read-host " What is the image name ?? "
            if ($NewIMName.Length -eq 0) {
                write-host "No image name given."
                exit-script
            } else {
                $createFolder=$true

            }
        }

    } while ($answ -inotmatch " y|Y|j|J")
    if ($createFolder) {
        New-Item -Path $scriptpath -name $newImName -ItemType directory -Confirm:$false -force | Out-Null
        write-host "Created image subfolder."

    }
    return $NewIMName
}

    Function add-Vibs2Image {
    <#
    .SYNOPSIS
        Add the selected vibs to the new ESXi Image profile
    .DESCRIPTION
        Add the selected vibs to the new ESXi Image profile
    #>
    Param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)][string]$ProjectPath,
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)][string]$NewImName
    )
        $SWPackageList=$null
        $SWPackageList=@()
        $viblist | %{
            $VIB=$_
            #-- add softwarepackages
            Get-EsxSoftwareDepot |  ?{$_.depoturl -ilike ("*"+$vib.name+"*")} | Get-EsxSoftwarePackage | %{
               $SWPackageList+=$_
            }
        }
        if ($noHA -eq $false) {
              #-- add HA vib to softwarepackages
              Get-EsxSoftwareDepot |  ?{$_.depoturl -ilike ("*"+ "http://"+ $FQDNvCenter +"/vSphere-HA-depot"+"*")} | Get-EsxSoftwarePackage | %{
                $SWPackageList+=$_
                }
            }
        #-- process softwarepackages
        if ($SWPackageList.count -ne 0) {
            #-- check if packages already are part of image
            $SWPackageList=$SWPackageList | select -Unique
            $Compare=Compare-Object -ReferenceObject (Get-EsxImageProfile -Name $NewIMName | select -ExpandProperty viblist | sort name) -DifferenceObject ($SWPackageList| sort name) -IncludeEqual
            $CompareGrouped=$Compare | Group-Object -Property sideindicator -AsHashTable
            if ($CompareGrouped."==") {
                #-- report software packages that already are part of image
                write-host ($CompareGrouped."==".count.ToString() +" software packages are being skipped, these are already part of the source image. see .\image\skipped.txt")
                $CompareGrouped."==" | select -ExpandProperty Inputobject | select name, summary,vendor,version,creationdate | sort-object name | ft -AutoSize | out-string -Width 256| Out-File -FilePath ($ProjectPath+'\Image\skipped.txt')
            }
            if ($CompareGrouped."=>") {
                #-- add the software packages to the image
                #-- the -unique parameter takes care of software packages that are exists in multiple vibs
                $drivers=@()
                $comparegrouped."=>" | select -ExpandProperty inputobject -Unique | select -ExpandProperty guid | %{$drivers+=$_}
                $CompareGrouped."=>" | select -ExpandProperty inputobject -Unique |  select name, summary,vendor,version,creationdate | sort-object name|ft -autosize |out-string -Width 256 | Out-File -FilePath $ProjectPath\Image\added.txt

                Add-EsxSoftwarePackage -ImageProfile $NewImName -SoftwarePackage $drivers
                write-host ("De volgende  "+ $CompareGrouped."=>".Count.tostring() + " software packages (vibs) are added: ")
                write-host ($CompareGrouped."=>" | select -ExpandProperty inputobject | select name, summary,vendor,version | out-string)
            }
        }
    }

    Function test-URL {
    <#
    .SYNOPSIS
        Basic testing on a given URL.
    .DESCRIPTION
        Basic testing on a given URL.
        We check if the response on a URL is 200 OK.
        Any other response is processed as invalid.
    .PARAMETER URL
        The URL to test.


    #>
    [cmdletbinding()]
    Param(
       [Parameter(Mandatory=$true,Position=0,ValueFromPipeLine=$true,HelpMessage="Enter a valid HTTP or HTTPS URL")] [string]$URL
    )
    #-- check if URL is valid
    if ($URL -inotmatch "^(http://|https://).*") {
        write-verbose "http:// or https:// not found at start of URL, using http://"
        $URL=("HTTP://"+$URL)
    }
    #-- Try http request
    try{
        # First we create the request.
        $HTTP_Request = [System.Net.WebRequest]::Create($URL)

        # We then get a response from the site.
        $HTTP_Response = $HTTP_Request.GetResponse()

    }
    Catch {
        #-- The HTTP request failed for some reason.
       switch -Regex ($error[0])
       {
            ".*The remote name could not be resolved.*" {
                write-warning "URL $URL is not responding."
                break
                }
            default {
                write-warning "Error while testing $URL."
                write-warning $error[0].Exception.message
            }
       }
    }


    # Check the HTTP response
    if ($http_response ) {
        $HTTP_Status = [int]$HTTP_Response.StatusCode
        If ($HTTP_Status -ne 200) {
            write-warning "$URL is not responding."
        }
    }

    # Finally, we clean up the http request by closing it.
    if ($HTTP_Response) {$HTTP_Response.Close()}
    return (($HTTP_Status -eq 200) -and ($HTTP_Response))
    }
#endregion

    #-- validate Powershell version
    if ($PSVersionTable.PSVersion.Major -lt 3) {
        write-host "PowerShell version is not valid, at least version 3 is needed."
        exit-script
    }
}

End{
    #-- call exit script
    exit-script
}

Process{
    #-- start of script
    #-- 1. load PowerCLI
    write-host "1. Loading PowerCLI"
    import-PowerCLI | out-null

    #-- Select Project folder
    $IMProject = get-imageProject
    $NewImName =get-ImageName -NewIMName $IMproject
    $ProjectPath="$scriptpath\$NewImName"

    #-- controleer de folderstrucuur
    $hadNoDirs=check-folderStructure -projectpath $projectpath

    #-- check if project has parameters.ps1 file
    if (Test-Path -Path ($ProjectPath + "\parameters.ps1")) {
        Write-Verbose "Found parameters.ps1 in $ProjectPath"
        $ProjectParam= & "$projectpath\parameters.ps1"
        if ($ProjectParam.ExcludeVIBS.count -gt 0) {
            #-- project parameters.ps1 contains VIBS to exclude
            if ($P.ContainsKey("ExcludeVibs") -eq $false) {
                #-- excludeVibs doesn't exist in $P, adding it
                $P.add("ExcludeVibs",@())
            }
            Write-Verbose "Found ExcludeVibs in project parameters file."
            $NewVibs2Exclude= Compare-Object -ReferenceObject $P.ExcludeVibs -DifferenceObject $ProjectParam.ExcludeVibs | ?{$_.SideIndicator -eq "=>"} | Select -ExpandProperty inputobject
            if ($NewVibs2Exclude) {
                #-- Add Vibs 2 exclude to $P.excludevibs 
                $NewVibs2Exclude | %{
                    $P.ExcludeVIBS+= $_
                    write-verbose "$_ added to exclusion list"
                }
            } else {
                write-verbose "No VIBS found in paramters.ps1 project
                 file to exclude"
            }
        }
    }

    #-- determine vCenter FQDN for HA vib
    $noHA=$noHA -or $hadNoDirs #-- The vib is not loaded when the folderstructure is not found.
    if ($noHA -eq $false) { $noHa=validate-vCenterFQDN -ProjectPath $ProjectPath }
    if ($noHA -eq $false) {
        #-- We are using the VMware HA vib, get the validated FQDN for the vCenter
        $FQDNvCenter=Import-Clixml -Path $ProjectPath\$xml_FQDNvCenter\vCenterFQDN.xml
    }


    #-- Check if export files exist in image folder
    $RunExports=(check-ImageFolder -NewIMName $NewIMName -ProjectPath $ProjectPath ) -and  -not $init

    # remove all software depots
    write-host "ESXi software depot initïaliseren"
    Get-EsxSoftwareDepot | %{  Remove-EsxSoftwareDepot -SoftwareDepot $_ -ErrorAction silentlycontinue}

    #-- Warn that possibly VIBs are going to be excluded
    if ($P.ExcludeVIBS.count -gt 0 ){
        Write-host "Extra input needed during proces, found VIBS to exlude."
    }

    #-- 2. Selecting offline bundle to use as source. Using or Source folder or VMware online software depot.
    $OfflineBundles=@()
    $useVMwareDepot=$useVMwareDepot -or $hadNoDirs #-- always use VMware depot when no folderstructure was found
    if (($useVMwareDepot -eq $false)) {
        #-- scan the Source folder for offline bundles
        [array]$OfflineBundles=Get-ChildItem -Path ($ProjectPath+"\Source") -Filter *.zip
        if ($OfflineBundles.count -eq 0) {write-host "No offline bundles found in $ProjectPath\Source"}
        }
    #-- Ask to use VMware online software depot when no offline bundles are found
    $UsingVMwareRepos=$false
    if (-not $OfflineBundles) {
        #-- no offline bundles found in .\Source folder, trying to use VMware Repository
        if ($useVMwareDepot) {
            write-host "VMware Online software depot is being used to select a source offline bundle."
            $answer="Y"
        } else {
            write-warning "No offline bundle(s) are found."
            $answer=read-host "Should we use VMware online software depot to select a source bundle ?? [y/N]"
        }
        if ($answer.length -eq 0) {$answer="N"}
        switch -Regex ($answer)  {
            "Y|y|j|J" { #--
                $UsingVMwareRepos=$true
                break
                }
            "n|N"  { #--
                exit-script
                break
                }
            "[^yYjJnN]" { #-- wrong input
                Write-Warning "Invalid answer."
                break
                }
        }
    } else {
        #-- Add files in Source folder to URL depot list.
        $URLDepots += Get-ChildItem -Path ($ProjectPath+"\Source") -Filter *.zip | select -ExpandProperty FullName
    }
    #-- check if VMware software depot URL is active

    if ($UsingVMwareRepos) {
    if ((test-URL -URL $P.VMwareDepot) -eq $false)  {
        Write-Warning "Couldn't reach VMware Software Depot."
        exit-script
    }
        write-host "Busy loading VMware Software Depot."
        $URLDepots += $P.VMwareDepot
        Add-EsxSoftwareDepot -DepotUrl $P.VMwareDepot | out-null
        #-- vanwege een bug moet er gefilterd worden, zie vmware KB 2089217 voor meer info
        #-- filter a.d.v. opgegeven VMware versie in image naam
        switch -Regex ($NewIMName) {
            #-- image naam is een IM-.... image
            "^IM-\d{2,2}(|(P|U|EP)\d{1,2})" {
                $version = $NewIMName.Substring(3,2)
                $tmpOnlineFilter=Filter-VMwareDepot -version $version
                break
                }
            #-- image naam is niet conform naamconventie
            default {$tmpOnlineFilter=Filter-VMwareDepot }
        }
        #-- select an image as the source
        $SourceIMName=Get-EsxImageProfile -Name $tmpOnlineFilter | select name,Vendor,Description,CreationTime | sort Name | Out-GridView -Title "Select an ESXi image"  -PassThru | select -ExpandProperty Name
        #-- check if name of the source and name of the new image are not the same
        if ($SourceIMName -imatch $NewIMName) {
            Write-Warning "Name for new image is the same as the source, please use a new name."
            $NewIMName=get-ImageName -noGuess
            if ($SourceIMName -imatch $NewIMName) {
                write-warning "The new image name exists in the software depot."
                write-warning "Script will exit."
                exit-script
            }
        }
        #-- check if we have a source image selected
        if (-not $SourceIMName) {
            write-warning "No source offline bundle is selected."
            exit-script
        }
        #-- export the selected  image to the source folder, and reload it. (so other image exports are using the local image instead of the remote image)
        $OfflineBundleDepot=export-BaseImage -SourceIMName $SourceIMName -NewIMName $newimname -projectPath $ProjectPath
        #-- use the exported offline bundle instead of the image from the VMware site
        Get-EsxSoftwareDepot | %{  Remove-EsxSoftwareDepot -SoftwareDepot $_ -ErrorAction silentlycontinue}
        Add-EsxSoftwareDepot -DepotUrl $OfflineBundleDepot
    }

    #-- Ask to put vibs in the vibs folder
    if ($hadNoDirs -or (!$hadnodirs -and !$noha)) {

        write-host ("Place VIB files in folder "+$scriptpath+"\"+$NewImName+"\Vibs")
        $answ=read-host "Are the vibs placed ? [y\N]"
        if ($answ -imatch "n|N") {
            $answ2=read-host "Continue without vibs ? [y/N] "
            if ($answ2 -inotmatch "j|J|y|Y") {
                exit-script
            }
        } elseif ($answ -inotmatch "j|J|y|Y" ) {
        exit-script}
   }

    #-- 3. 	laad de drivers en offline bundle
    write-host "3. Compose software depot"
    #-- bouw lijst van bestanden die geladen moet worden
    Get-ChildItem -Path ($ProjectPath+"\Vibs") -Filter *.zip -Recurse | select -ExpandProperty Fullname | %{
        $row= "" | select Name
        $row.name=$_
        $viblist += $row
    }
    #-- voeg de vib bestanden toe
    if ($viblist.count -eq 0) {
        Write-Warning "No vibs available."
    } else {
        $VibList | %{$urlDepots += $_.Name}
    }
    #-- add url for HA vib
    if ($noHA -eq $false) {
        $URLDepots += "http://"+ $FQDNvCenter +"/vSphere-HA-depot" }

    #-- laad de bestanden
    if ($URLDepots.count -eq 0) {
        write-error "No valid software depot to use."
        exit-script
    }
    $URLDepots.GetEnumerator() | %{Add-EsxSoftwareDepot -DepotUrl $_ | out-null}


    #-- 4. Clone het image profile uit de offline bundle
    Write-host "4. Building new ESXi Image profile $NewIMName ."

    #-- check if name of new image is not already known
    if (Get-EsxImageProfile -name $NewIMName) {
        Write-Warning "New image name already exists in software depot, please change the name for the new image."
        $NewIMName=get-ImageName -noGuess
        if ($SourceIMName -imatch $NewIMName) {
            write-warning "The name for the new image exists in the software depots."
            write-warning "Script cannot continue."
            exit-script
        }
    }


    #--clone to new image profile
    if (-not($UsingVMwareRepos)) {
        $tmp=Get-EsxImageProfile | ?{$_.name -match "\d-standard$" } | sort | select -First 1 -ExpandProperty name
        $SourceIMName=(get-EsxImageProfile | select name | Out-GridView -Title "Select source offline bundle to use?"   -PassThru).name
        if ($SourceIMName.length -lt 1) {$SourceIMName=$tmp}
    }

    New-EsxImageProfile -CloneProfile $SourceIMName -Name $NewIMName -Vendor VMware | select Name,Vendor,Description,CreationTime | ft -AutoSize

    #-- 5. VIBs toevoegen aan image
    Write-host "5. Toevoegen van vibs aan het nieuwe image profile $NewIMName."
    if ((($VibList.count -ne 0) -or ($noHA -eq $false)) ) { add-Vibs2Image -ProjectPath $projectpath -NewImName $NewIMName }


    #-- 5b. Exclude vibs
    if ($p.ExcludeVIBS.count -gt 0) {
        #-- find vibs in new imageprofile to exclude
        $IMProfile=Get-EsxImageProfile -Name $NewImName
        $Vibs2Exclude=Compare-Object -ReferenceObject ($IMProfile).VibList.name -DifferenceObject $P.ExcludeVIBS -IncludeEqual -ExcludeDifferent | select -ExpandProperty Inputobject
        if ($Vibs2Exclude) {
            #-- found vibs in imageprofile to remove
            write-host "Found the following vibs in the new image to exclude:"
            $Vibs2Exclude | %{write-host "   " + $_}
            $removedVibs=@()
            $vibs2Exclude | %{
                #-- remove vib
                $Vib2Remove=$_
                $VIB=Get-EsxSoftwarePackage -Name $vib2remove
                Remove-EsxSoftwarePackage -ImageProfile $newimname -SoftwarePackage $Vib2Remove -ErrorVariable Err1 -ErrorAction SilentlyContinue
                if ($Err1) {
                    #-- failed to remove vib
                    Write-Warning "Error removing VIB " + $Vib2Remove
                    Write-warning $Err1
                } else {
                    #-- Vib removed
                    Write-Verbose "Removed "+ $vib2remove
                    $RemovedVibs+=$VIB
                }
            }
            #-- write to file which VIBS are removed
            Out-File -FilePath $ProjectPath\Image\Excluded.txt -InputObject ($RemovedVibs | Select Name,Vendor,Version,Summary,Description | ft -AutoSize | Out-String -Width 4096)
        }
    }

    #-- create parameters.ps1 file in project folder
    if ($P.ExcludeVIBS) {
        if (Test-Path $projectpath\parameters.ps1) {
            write-host "Parameters.ps1 exists in project folder, it will be overwritten."
        }
        #-- write excluded vibs to parameters.ps1 in project folder
        new-item -Path $projectpath -Name parameters.ps1 -force 
        add-content -path $projectpath\parameters.ps1 -value "#-- Automaticly generated"
        Add-Content -Path $projectpath\parameters.ps1 -Value "@{"
        Add-Content -Path $projectpath\parameters.ps1 -Value "    ExcludeVIBS=@("
        $I=$p.ExcludeVIBS.count
        $P.ExcludeVIBS | %{
            if ($I -gt 1) {
                Add-Content -PassThru $projectpath\parameters.ps1 -Value ("    `"" + $_+ "`",") 
            } else {
                Add-Content -PassThru $projectpath\parameters.ps1 -Value ("    `"" + $_ + "`"")
            }
            $I--         
        }
        Add-Content -PassThru $projectpath\parameters.ps1 -Value ("    )")
        Add-Content -PassThru $projectpath\parameters.ps1 -Value ("}")
    }

    #-- 6. image exporteren als offline bundle en als .iso
    write-host "6. Exporting Image profile $NewIMName  to a offline bundle and .iso"
    if ($RunExports) {export-Images -NewIMName $NewIMName -ProjectPath $ProjectPath }
    #-- list content of image folder
    Get-ChildItem  -path ("$ProjectPath\image") | ft -a
}
