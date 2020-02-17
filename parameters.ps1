@{
    #-- string to filter items in VMware Online Depot
    VMwareOnlineFilter = "ESXi-6.5.*-standard" #-- other options are : ESXi-6.0.*-standard, ESXi-6.5.*-standard, ESXi-5.1.*-standard, ESXi-5.5.*-standard
    #-- VMware Online depot URL
    VMwareDepot="https://hostupdate.vmware.com/software/VUM/PRODUCTION/main/vmw-depot-index.xml"
    #-- are IM project folders siblings 
    ProjectIMFoldersAreSiblings=$false
    
    #-- subfolder for script functions
    FunctionsSubFolder="functions"

    #-- Excluded VIBs
    ExcludeVIBS=@(
    )
}