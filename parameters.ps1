@{
    #-- string to filter items in VMware Online Depot
    VMwareOnlineFilter = "ESXi-6.*-standard"
    #-- VMware Online depot URL
    VMwareDepot="https://hostupdate.vmware.com/software/VUM/PRODUCTION/main/vmw-depot-index.xml"
    #-- are IM project folders siblings 
	ProjectIMFoldersAreSiblings=$false

    #-- Excluded VIBs
    ExcludeVIBS=@(
        "lsi-mr3",   #-- conflicts cisco megaraid scsi driver
        "lsi-msgpt3" #-- conflicts cisco megaraid scsi driver
    )
}