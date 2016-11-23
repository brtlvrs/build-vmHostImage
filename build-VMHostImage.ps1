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
    Version            : 0.1
    Copyright 2016 - Bart Lievers
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

    function import-PowerCLi {
    <#
    .SYNOPSIS
       Loading of all VMware modules and power snapins
    .DESCRIPTION

    .EXAMPLE
        One or more examples for how to use this script
    .NOTES
        File Name          : import-PowerCLI.ps1
        Author             : Bart Lievers
        Prerequisite       : <Preruiqisites like
                             Min. PowerShell version : 2.0
                             PS Modules and version :
                                PowerCLI - 5.5
        Last Edit          : BL - 22-11-2016
    #>
    [CmdletBinding()]

    Param(
    )

    Begin{

    }

    Process{
        #-- make up inventory and check PowerCLI installation
        $RegisteredModules=Get-Module -Name vmware* -ListAvailable -ErrorAction ignore | % {$_.Name}
        $RegisteredSnapins=get-pssnapin -Registered vmware* -ErrorAction Ignore | %{$_.name}
        if (($RegisteredModules.Count -eq 0 ) -and ($RegisteredSnapins.count -eq 0 )) {
            #-- PowerCLI is not installed
            if ($log) {$log.warning("Cannot load PowerCLI, no VMware Powercli Modules and/or Snapins found.")}
            else {
            write-warning "Cannot load PowerCLI, no VMware Powercli Modules and/or Snapins found."}
            #-- exit function
            return $false
        }

        #-- load modules
        if ($RegisteredModules) {
            #-- make inventory of already loaded VMware modules
            $loaded = Get-Module -Name vmware* -ErrorAction Ignore | % {$_.Name}
            #-- make inventory of available VMware modules
            $registered = Get-Module -Name vmware* -ListAvailable -ErrorAction Ignore | % {$_.Name}
            #-- determine which modules needs to be loaded, and import them.
            $notLoaded = $registered | ? {$loaded -notcontains $_}

            foreach ($module in $registered) {
                if ($loaded -notcontains $module) {
                    Import-Module $module
                }
            }
        }

        #-- load Snapins
        if ($RegisteredSnapins) {      
            #-- Exlude loaded modules from additional snappins to load
            $snapinList=Compare-Object -ReferenceObject $RegisteredModules -DifferenceObject $RegisteredSnapins | ?{$_.sideindicator -eq "=>"} | %{$_.inputobject}
            #-- Make inventory of loaded VMware Snapins
            $loaded = Get-PSSnapin -Name $snapinList -ErrorAction Ignore | % {$_.Name}
            #-- Make inventory of VMware Snapins that are registered
            $registered = Get-PSSnapin -Name $snapinList -Registered -ErrorAction Ignore  | % {$_.Name}
            #-- determine which snapins needs to loaded, and import them.
            $notLoaded = $registered | ? {$loaded -notcontains $_}

            foreach ($snapin in $registered) {
                if ($loaded -notcontains $snapin) {
                    Add-PSSnapin $snapin
                }
            }
        }
        #-- show loaded vmware modules and snapins
        if ($RegisteredModules) {get-module -Name vmware* | select name,version,@{N="type";E={"module"}} | ft -AutoSize}
          if ($RegisteredSnapins) {get-pssnapin -Name vmware* | select name,version,@{N="type";E={"snapin"}} | ft -AutoSize}

    }

    End{

    }
    }

    function unload-PowerCLI {
        if (Get-PSSnapin -Name "VMware*") {
            Get-PSSnapin -Name "VMware*" | Remove-PSSnapin
            write-host "PowerCLI snappins worden verwijderd uit het geheugen."
            }
    }

    function validate-ImageName {
    <#
    .SYNOPSIS
        Validate Image name to export conform Naming Convention
    .DESCRIPTION
        Validate the the input.
        Name convention image name :
        IM-CC<Prefix>ESXi<main version><sub version>-<datestamp>

        IM = Image
        CC = CAMCube
        <Prefix> = Empty, W(erkplek), or M(achinekamer)
        <main version> = VMware ESXi version. 2 digits. Like 55 for Version 5.5
        <sub version>  = Patch, Express Patch or Update number.
                            Allowed characters are P(patch), EP (express patch) or U (update)
        <datestamp>    = Creation date.
                         Format YYYYMMDD
                            YYYY = 4 digit year
                            MM   = 2 digit Month
                            DD   = 2 digit day

        Examples :
            IM-CCESXi55-20150607      =  VMware ESXi 5.5 image for CAMCube (werkplek and Machinekamer) created on june the 7th 2015
            IM-CCWESXi60U2-20150607   =  VMware ESXi 6.0 Update 2 image for CAMCube werkplek, created on june the 7th 2015
            IM-CCMESXi50EP12-20150607 =  VMware ESXi 5.0 Express Patch 12 image for CAMCube machinekamer, created on june the 7th 2015
    #>
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory,Helpmessage="Image name to validate")][string]$ImageName,
        [Parameter(Helpmessage="Display explaination when name is not according to convention.")][switch]$Explain
    )
    #-- check prefix
    $Pre= $ImageName -match "^IM-CC(E|WE|ME)"
    #-- validate ESXi version
    $ESXiVersion=$imagename.Substring(5) -match "(|W|M)ESXi\d{2,2}(|(P|U|EP))\d{1,2}"
    #-- validate date stamp
    $dateStamp=$imagename.Split("-")[2] -match "\d{4,4}(0[1-9]|1[0-2])(0[1-9]|(1|2)[0-9]|3[0-1])$"
    #-- write explenation
    if (-not($pre -and $ESXiVersion -and $dateStamp) -and $Explain) {
        write-warning "Image naam $imagename is niet conform conventie."
        Write-host ""
        write-host "Conventie     : " -NoNewline        if (-not($pre)) {$tmp=@{ForegroundColor="yellow"}}        else {$tmp=""}        write-host "<Prefix>" @tmp -NoNewline        if (-not($ESXiVersion)) {$tmp=@{ForegroundColor="yellow"}}        else {$tmp=""}        write-host "<ESXi versie>" -NoNewline @tmp        if (-not($dateStamp)) {$tmp=@{ForegroundColor="yellow"}}        else {$tmp=""}        write-host "-<Datum stempel>" @tmp        write-host "              : vb. IM-CCMESXi55EP6-20150515"        write-host "                    Image profile voor MK hosts, ESXi 5.5 Express patch 6, "        write-host "                    aangemaakt op 15 mei 2015"        write-host "Prefix        : IM-CC of IM-CCW of IMCCM"
        write-host "ESXi versie   : ESXiAABB"        write-host "        AA    : ESXi versie, b.v. 55 voor 5.5"        write-host "        BB    : Patch versie.  EP = express patch,"        write-host "                               P  = Patch,"        write-host "                               U  = Update"        write-host "                Expres Patch 5 = EP5."        write-host "                Wordt weggelaten bij GA versie."
        write-host "Datum stempel : YYYYMMDD"        write-host "                YYYY = jaar"        write-host "                MM   = maand (incl. voorloop nul) 01 t/m 12"
        write-host "                DD   = dag   (incl. voorloop nul) 01 t/m 31"
    }
    #-- return validation
    return ($pre -and $ESXiVersion -and $dateStamp)
    }

    function check-folderStructure {
    <#
    .SYNOPSIS
        Check if subfolder structure is inplace
    .DESCRIPTION
        Check if subfolder structure is inplace.
        And create missing subfolders.
        Returns $true if image or source folder isn't present
    #>
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)][string]$ProjectPath
    )
        #-- check if folderstructure is inplace, if not, create it.
        $isNoDir=$false
        if ((Test-Path -Path "$ProjectPath\image") -eq $false) {
            write-warning "Image folder ontbreekt, deze wordt aangemaakt."
            New-Item -ItemType Directory -Path "$ProjectPath\Image" | Out-Null
            $isnoDir = $isNoDir -or $true
        }
        if ((Test-Path -Path "$ProjectPath\Vibs") -eq $false) {
            write-warning "Vibs folder ontbreekt, deze wordt aangemaakt."
            New-Item -ItemType Directory -Path "$ProjectPath\Vibs"  | Out-Null
        }
        if ((Test-Path -Path "$ProjectPath\Source") -eq $false) {
            write-warning "Source (Offline Bundle) folder ontbreekt, deze wordt aangemaakt."
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
        If files exist, ask if they should be remoted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)][string]$ProjectPath,
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)][string]$NewImName

    )

    $runExport=$false
    if (Get-ChildItem -Path ("$ProjectPath\image") | ?{$_.fullname -match "$NewIMName.zip|$NewImName.iso"}) {
        write-host "Kan niet exporteren, offline bundle en/of .iso bestanden bestaan al."
            do {
                #-- vraag of bestaande bestanden verwijderd mogen worden.
                $answ=read-host "Bestaande bestanden verwijderen ? [j/N] :  "
                switch -Regex ($answ)  {
                    "" {
                        #-- Geen input gegeven, dus gebruik default
                        $answ="N"}
                    "Y|y|j|J" {
                        #-- remove old files
                        $RunExport=$true
                        write-host "Bezig met verwijderen van bestaande offline bundle en .iso in image folder."
                        Get-ChildItem -Path ("$ProjectPath\image") | ?{$_.fullname -match "$NewIMName.zip|$NewImName.iso"} | Remove-Item -Force
                        break
                        }
                    "[^yYjJnN]" {
                        #-- wrong input
                        Write-Warning "Ongeldige input."
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
    $row.Filter="ESXi-6.*-standard"
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
        [parameter(Mandatory=$true,helpmessage="Naam van het te exporteren image.")][string]$NewIMName,
        [Parameter(helpmessage="Subfolder waarin de images worden opgeslagen.")][string]$exportFolderName="Image"
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
        write-host "Bezig met Exporteren van VMware Offline Bundle $SourceIMName naar Offline Bundle folder"
        $exportpath="$ProjectPath\Source\$SourceIMName.zip"
        $answer=$false
        if (Get-ChildItem -Path ("$ProjectPath\Source") | ?{$_.fullname -match "$SourceIMName.zip"}) {
            do {
                $answer=read-host "$SourceIMName bestaat al in folder Offline Bundle, vervangen ? [j/N]"
                if ($answer.Length -eq 0) {$answer="N"}
                switch -Regex ($answer)  {
                    "Y|y|j|J" {
                        Remove-Item -Path $exportpath -Force
                        break
                        }
                    "[^yYjJnN]" {
                        #-- wrong input
                        Write-Warning "Ongeldige input."
                        break
                        }
                }
            } while  ($answer -inotmatch " y|Y|j|J|n|N")
        }
        #-- Export Image profile to offline bundle in offline bundle folder
        if (($answer -imatch "j|J|y|Y") -or -not($answer)) {
            write-host "Image $SourceIMName wordt als offline bundle ge-exporteerd."
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
        [string]$FQDNvCenter=read-host ("Wat is de FQDN van de vCenter server om de HA vib te laden ? ["+$def_FQDNvCenter+"]")
        do {
            $validFQDN=$false

            if (($FQDNvCenter.Length -eq 0) -and  ($def_FQDNvCenter.Length -eq 0)  ) {
                write-warning "Geen geldige FQDN opgegeven van de vCenter om HA vib te gebruiken."
            }
            if ($FQDNvCenter.Length -eq 0) {
                $FQDNvCenter = $def_FQDNvCenter
            }

            #-- test if vCenter is alive
            if ($FQDNvCenter.Length -eq 0) {
                $noHA=$true
            } elseif (-not(Test-Connection -ComputerName $FQDNvCenter -Count 1 -Quiet)) {
                Write-Warning "vCenter $FQDNvCenter reageert niet."
                $FQDNvCenter=read-host "Wat is de FQDN van de vCenter server ? "
                if ($FQDNvCenter.Length -eq 0) {
                    #-- geen input gekregen, gaan door zonder vib voor HA
                    $noHA=$true
                    write-host "Geen input gehad, HA vib wordt overgeslagen."
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
            $IMProject= $IMprojects | Out-GridView -OutputMode Single -Title "Selecteer ESXi Image Project ([Cancel] voor een nieuw project)" | select -ExpandProperty name
        } else {
            write-host "Geen subfolders gevonden met een vmHost image (IM-*)."
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
            if (-not(validate-ImageName -ImageName $NewIMName -Explain)) {
                write-warning "Image naam is niet conform naam conventie."
            }
        }
        if ($newIMName.Length -gt 0) {
            Write-Host "Image name : " $NewIMName
            $answ=Read-Host "Is dit correct ? [j/N]"
        }
        if ($answ.Length -eq 0) {$answ="N"} #-- default input
        if ($answ -imatch "n|N") {
            $NewIMName=read-host " Wat wordt de naam van het image ?? "
            if ($NewIMName.Length -eq 0) {
                write-host "Geen naam opgegeven."
                exit-script
            } else {
                $createFolder=$true

            }
        }

    } while ($answ -inotmatch " y|Y|j|J")
    if ($createFolder) {
        New-Item -Path $scriptpath -name $newImName -ItemType directory -Confirm:$false -force | Out-Null
        write-host "Image subfolder aangemaakt."

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
        write-verbose "URL begint niet met http:// of https://, we proberen http://"
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
                write-warning "URL $URL reageert niet."
                break
                }
            default {
                write-warning "Fout bij testen van URL $URL."
                write-warning $error[0].Exception.message
            }
       }
    }


    # Check the HTTP response
    if ($http_response ) {
        $HTTP_Status = [int]$HTTP_Response.StatusCode
        If ($HTTP_Status -ne 200) {
            write-warning "$URL reageert niet."
        }
    }

    # Finally, we clean up the http request by closing it.
    if ($HTTP_Response) {$HTTP_Response.Close()}
    return (($HTTP_Status -eq 200) -and ($HTTP_Response))
    }
#endregion

    #-- validate Powershell version
    if ($PSVersionTable.PSVersion.Major -lt 3) {
        write-host "PowerShell versie is te laag. Minimaal versie 3 vereist."
        exit-script
    }
}

End{
    #-- call exit script
    exit-script
}

Process{
    #-- start of script
    #-- 1. laad de PowerCLI modules
    write-host "1. Loading PowerCLI"
    import-PowerCLI | out-null

    #-- Select Project folder
    $IMProject = get-imageProject
    $NewImName =get-ImageName -NewIMName $IMproject
    $ProjectPath="$scriptpath\$NewImName"

    #-- determine Image name according to foldername and validate it


    #-- controleer de folderstrucuur
    $hadNoDirs=check-folderStructure -projectpath $projectpath

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

    #-- 2. Selecting offline bundle to use as source. Using or Source folder or VMware online software depot.
    $OfflineBundles=@()
    $useVMwareDepot=$useVMwareDepot -or $hadNoDirs #-- always use VMware depot when no folderstructure was found
    if (($useVMwareDepot -eq $false)) {
        #-- scan the Source folder for offline bundles
        [array]$OfflineBundles=Get-ChildItem -Path ($ProjectPath+"\Source") -Filter *.zip
        if ($OfflineBundles.count -eq 0) {write-host "Geen Offline bundles gevonden in $ProjectPath\Source"}
        }
    #-- Ask to use VMware online software depot when no offline bundles are found
    $UsingVMwareRepos=$false
    if (-not $OfflineBundles) {
        #-- no offline bundles found in .\Source folder, trying to use VMware Repository
        if ($useVMwareDepot) {
            write-host "VMware Online software depot wordt gebruikt om een source te selecteren."
            $answer="Y"
        } else {
            write-warning "Er zijn geen Offline Bundle(s) gevonden."
            $answer=read-host "VMware online software depot gebruiken om source te selecteren ?? [j/N]"
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
                Write-Warning "Ongeldige input."
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
        Write-Warning "VMware Online software depot is niet te bereiken."        exit-script
    }
        write-host "Bezig met laden van VMware online software depot."
        $URLDepots += $P.VMwareDepot
        Add-EsxSoftwareDepot -DepotUrl $P.VMwareDepot | out-null
        #-- vanwege een bug moet er gefilterd worden, zie vmware KB 2089217 voor meer info
        #-- filter a.d.v. opgegeven VMware versie in image naam        switch -Regex ($NewIMName) {            #-- image naam is een IM-CCESXi.... image            "^IM-CCESXi\d{2,2}(|(P|U|EP)\d{1,2})" {                $version = $NewIMName.Substring(9,2)                $tmpOnlineFilter=Filter-VMwareDepot -version $version                break                }            #-- image naam is een IM-CCMESXi.... of een IM-CCWESXi.... image            "^IM-CC(W|M)ESXi\d{2,2}(|(P|U|EP)\d{1,2})"{                $version = $NewIMName.Substring(10,2)                $tmpOnlineFilter=Filter-VMwareDepot -version $version                break                }            #-- image naam is niet conform naamconventie            default {$tmpOnlineFilter=Filter-VMwareDepot }        }
        #-- select an image as the source
        $SourceIMName=Get-EsxImageProfile -Name $tmpOnlineFilter | select name,Vendor,Description,CreationTime | sort Name | Out-GridView -Title "Selecteer een ESXi image"  -PassThru | select -ExpandProperty Name
        #-- check if name of the source and name of the new image are not the same
        if ($SourceIMName -imatch $NewIMName) {
            Write-Warning "Het gekozen image naam komt voor in het VMware Depot, kies een andere naam voor het nieuwe image."
            $NewIMName=get-ImageName -noGuess
            if ($SourceIMName -imatch $NewIMName) {
                write-warning "Het gekozen image naam komt voor in het VMware Depot."
                write-warning "Script kan niet verder uitgevoerd worden."
                exit-script
            }
        }
        #-- check if we have a source image selected
        if (-not $SourceIMName) {
            write-warning "Er is geen offline bundle als source geselecteerd."
            exit-script
        }
        #-- export the selected  image to the source folder, and reload it. (so other image exports are using the local image instead of the remote image)
        $OfflineBundleDepot=export-BaseImage -SourceIMName $SourceIMName -NewIMName $newimname -projectPath $ProjectPath
        #-- use the exported offline bundle instead of the image from the VMware site
        Get-EsxSoftwareDepot | %{  Remove-EsxSoftwareDepot -SoftwareDepot $_ -ErrorAction silentlycontinue}
        Add-EsxSoftwareDepot -DepotUrl $OfflineBundleDepot
    }

    #-- Exit script if script started without subfolders.
    if ($hadNoDirs) {

        write-host ("Plaats de VIB bestanden in de locatie "+$scriptpath+"\"+$NewImName+"\Vibs")
        $answ=read-host "Zijn de VIB bestanden geplaatst ? [j\N]"
        if ($answ -inotmatch "j|J|y|Y" ) {
        exit-script}
   }

    #-- 3. 	laad de drivers en offline bundle
    write-host "3. ESXi software Depot opbouwen aan de hand van offline bundle en drivers"
    #-- bouw lijst van bestanden die geladen moet worden
    Get-ChildItem -Path ($ProjectPath+"\Vibs") -Filter *.zip -Recurse | select -ExpandProperty Fullname | %{
        $row= "" | select Name
        $row.name=$_
        $viblist += $row
    }
    #-- voeg de vib bestanden toe
    if ($viblist.count -eq 0) {
        Write-Warning "Geen Vibs gevonden."
    } else {
        $VibList | %{$urlDepots += $_.Name}
    }
    #-- add url for HA vib
    if ($noHA -eq $false) {
        $URLDepots += "http://"+ $FQDNvCenter +"/vSphere-HA-depot" }

    #-- laad de bestanden
    if ($URLDepots.count -eq 0) {write-error "Geen software depots om te laden."}
    $URLDepots.GetEnumerator() | %{Add-EsxSoftwareDepot -DepotUrl $_ | out-null}

    #-- 4. Clone het image profile uit de offline bundle
    Write-host "4. Nieuw ESXi image profile $NewIMName aan het maken."

    #-- check if name of new image is not already known
    if (Get-EsxImageProfile -name $NewIMName) {
        Write-Warning "De naam van het nieuwe image komt al voor in de gekozen Offline bundles. Kies een andere naam voor het image."
        $NewIMName=get-ImageName -noGuess
        if ($SourceIMName -imatch $NewIMName) {
            write-warning "De naam van het nieuwe image komt al voor in de gekozen Offline bundles."
            write-warning "Script kan niet verder uitgevoerd worden."
            exit-script
        }
    }


    #--clone to new image profile
    if (-not($UsingVMwareRepos)) {
        $tmp=Get-EsxImageProfile | ?{$_.name -match "\d-standard$" } | sort | select -First 1 -ExpandProperty name
        #$SourceIMName= Read-Host "Wat is de naam van het Image Profile die als basis gebruikt moet worden ?? [" $tmp "]"
        $SourceIMName=(get-EsxImageProfile | select name | Out-GridView -Title "Welk ESXi image profile dient als basis ?"   -PassThru).name
        if ($SourceIMName.length -lt 1) {$SourceIMName=$tmp}
    }

    New-EsxImageProfile -CloneProfile $SourceIMName -Name $NewIMName -Vendor VMware | select Name,Vendor,Description,CreationTime | ft -AutoSize
    #-- 5. VIBs toevoegen aan image
    Write-host "5. Toevoegen van vibs aan het nieuwe image profile $NewIMName."
    if ((($VibList.count -ne 0) -or ($noHA -eq $false)) ) { add-Vibs2Image -ProjectPath $projectpath -NewImName $NewIMName }

    #-- 6. image exporteren als offline bundle en als .iso
    write-host "6. Image profile $NewIMName  exporteren als offline bundle en .iso"
    if ($RunExports) {export-Images -NewIMName $NewIMName -ProjectPath $ProjectPath }
    #-- list content of image folder
    Get-ChildItem  -path ("$ProjectPath\image") | ft -a
}
