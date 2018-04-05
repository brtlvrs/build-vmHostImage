function exit-script {
    <#
    .SYNOPSIS
       function to exit script cleanly.
    .DESCRIPTION
        When you have script with for instance loops, and you want to exit the script always in the same way, you call this function.
        If a $log object exists, it wil use it to write to the log file.

        Add the folowwing code to the end{} scriptblock of the script

        End{
            $finished_normal=$true
            exit-script
        }

        This wil call the exit-script function and return the execution time of the script and 
        the message that the script code executed without errors.

        Add to the parameters.ps1 file the following scriptblock when clean up tasks need to run before exiting script.
        
        cleanUpCodeOnExit={
            #--- PS code to run before leaving the script, like disconnecting from vSphere enviroment
            disconnect-viserver * -erroraction silentlycontinue -confirm:$false
        }

       .PARAMETER defaultcleanupcode
        [scriptblock] Input parameter of type scriptblock.
        code to be run during exiting script. p.e. clode to clean up variables, or to disconnect from remote services etc...
    .EXAMPLE
        Errorhandling

        get-childitem someting -errorvariable err1 -erroraction silentlycontinue
        if ($err1) {
            write-host "Something happened, can't execute code."
            exit-script
        }    
    
    .NOTES
        function            : exit-script
        Author              : Bart Lievers
        Dependencies        :
    #>
    [CmdletBinding()]
    Param(
          [scriptblock]$defaultcleanupcode)

    if ($finished_normal) {
        $msg= "Hooray.... finished without any bugs....."
        if ($log) {$log.verbose($msg)} else {Write-Verbose $msg}
    } else {
        $msg= "(1) Script ended with errors."
        if ($log) {$log.error($msg)} else {Write-Error $msg}
    }

    #-- execute cleanup actions
    if ($p.cleanUpCodeOnExit) {
        $p.cleanUpCodeOnExit.invoke()
    }

    #-- run unique code 
    if ($defaultcleanupcode) {
        $defaultcleanupcode.Invoke()
    }
    
    #-- Output runtime and say greetings
    if ($ts_start) { #-- when there is a start timestamp return duration of script execution
        $ts_end=get-date
        $msg="Runtime script: {0:hh}:{0:mm}:{0:ss}" -f ($ts_end- $ts_start)  
        if ($log) { $log.msg($msg)  } 
        else {write-host $msg}
    }
    read-host "The End <press Enter to close window>."
    exit
    }