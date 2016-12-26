**build-vmHostImage**
PowerCLI workflow script for building VMware vSphere ESXi images

### LICENSE
This script is released under the MIT license. See the License file for more details

### CHANGE LOG
|build|branch |  Change |
|---|---|---|
|0.2| Master| Current version |
|0.2| release/v0.2| Subroutines to exclude vibs from new image|
|0.1| release/v0.1| Initial code|
|0.0| Master| Initial release|

### How do I get set up?  
1. Download script
2. Modify parameters in parameters.ps1
3. (optional) If folder structure is already in place, put VIBS in the vib subfolder of the image profile folder
3. run script
(scrip will ask to place VIBS, if vibs are not found and create subfolder structure if needed.)



#### Dependencies

	- PowerShell 3.0
	- PowerCLI > 5.x