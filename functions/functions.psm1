<#
Code to add to the begin{} block of a script

    #-- load functions
    import-module $scriptpath\functions\functions.psm1 #-- the module scans the functions subfolder and loads them as functions
    #-- add code to execute during exit script. Removing functions module
    $p.Add("cleanUpCodeOnExit",{remove-module -Name functions -Force -Confirm:$false})

#>

write-verbose "Loading script functions."
# Gather all files
$Functions  = @(Get-ChildItem -Path ($scriptpath+"\functions") -Filter *.ps1 -ErrorAction SilentlyContinue)

# Dot source the functions
ForEach ($File in @($Functions)) {
    Try {
        . $File.FullName
    } Catch {
        Write-Error -Message "Failed to import function $($File.FullName): $_"
    }       
}

# Export the public functions for module use
Export-ModuleMember -Function $Functions.Basename
