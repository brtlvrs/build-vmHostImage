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