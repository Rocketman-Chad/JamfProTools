#!/bin/bash

####################################################################################################
#
# ABOUT THIS PROGRAM
#
# NAME
#	makeMeAnAdmin.sh -- Grants temporary admin rights to standard users through Self Service
#
# SYNOPSIS
#	sudo makeMeAnAdmin.sh
#	sudo makeMeAnAdmin.sh <mountPoint> <computerName> <currentUsername> [time in minutes] 
#
#
# DESCRIPTION
#
#	This script is to be used with a self service policy and grants the user admin rights
#	for a time (in minutes) specified in $4 through the policy.
#
#	This script is based on the one created by Jamf (https://github.com/jamf/MakeMeAnAdmin)
#
#
####################################################################################################
#
# HISTORY
#
#	Version: 0.1 - Chad Lawson on 11/12/2018
#	Version: 1.0 - Chad Lawson on 11/11/2020
#	Version: 2.0a - Chad Lawson on 1/27/2021
#		Added code to:
#			* Ask the user why the need it (optional)
#			* Upload the logs as a file attachment (optional)
#			* Remove the computer from a static group after running (optional)
#	Version: 2.1 - Chad Lawson on 3/30/2021
#		Added block at end to perform 'checkmember' and echo result for verification
#
####################################################################################################
#
# Future upgrades:
#	* Add code to verify all components are removed
#	* Complete code to gather logs and add to fileuploads 
#
####################################################################################################

STATUS=0 ## default

## Hopefully you never need this
function debugLog () {
	local logFile=$1
	local logText=$2
	local timeStamp=$(date +'%Y-%m-%d %H:%M:%S')
	echo "${timeStamp}: ${logText}" >> ${logFile}
}

## Getting the user "the apple way" instead of grabbing $3
## Source: https://macmule.com/2014/11/19/how-to-get-the-currently-logged-in-user-in-a-more-apple-approved-way/
currentUser=$(who | awk '/console/{print $1}')

## $4 = Time (in minutes) for admin rights
TIMEMIN=$( [ $4 ] && echo $4 || echo "5" ) ## defaults to 5 minutes if not specified
TIMESEC=$(( ${TIMEMIN} * 60 ))

## $5 = Ask for reason (y/n)
## If true, the user will be prompted with an AppleScript dialog why they need admin rights and the reason
## will be echoed out to the policy log.
ASKREASON=$5

## $6 = API user hash*
## 	*hash = base64 encoded string of 'user:password' for an API user for the next two options
##		Note: Yes, I know this isn't a 'hash' but the word is more concise
## 	If provided, this string will be used in an API call to file upload the logs at the end
APIHASH=$6
if [[ ${APIHASH} ]]; then
	JSSURL=$(defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url)
	SERIAL=$(system_profiler SPHardwareDataType | awk '/Serial Number/ {print $NF}')
	COMPID=$(curl -sk -H "Authorization: Basic ${APIHASH}" -H "Accept: text/xml" "${JSSURL}JSSResource/computers/serialnumber/${SERIAL}" | xmllint --xpath '/computer/general/id/text()' -)
fi

## $7 = Upload logs to Jamf (y/n)
## If yes, the system logs for the duration of elevated rights will be attached to the computer record in Jamf
## Note: The API user 'hash' above must be provided above and that user must have the following permissions:
##		Computers - Create
##		File Uploads - Create Read Update
UPLOADLOG=$7
if [[ ${UPLOADLOG} == "y" && ${APIHASH} ]]; then
	TIMESTAMP=$(date +'%Y%m%d-%H%M%S')
    LOGUPLOAD="log collect --last ${TIMEMIN}m --output /private/var/userToRemove/${currentUser}.logarchive ; zip -rm /private/var/userToRemove/${currentUser}.logarchive-${TIMESTAMP}.zip /private/var/userToRemove/${currentUser}.logarchive ; curl -sk -H 'Authorization: Basic ${APIHASH}' '${JSSURL}JSSResource/fileuploads/computers/id/${COMPID}' -F name=@'/private/var/userToRemove/${currentUser}.logarchive-${TIMESTAMP}.zip' -X POST"
	LOGCOMMAND=$(echo $LOGUPLOAD | sed -e 's:/:\\/:g') ## To properly escape the slashes
fi

## $8 = Remove computer from group after granting access?
## If this parameter exists, it must be the name of a static computer group.
## Note: The API user 'hash' above must be provided above and that user must have the following permissions:
##		Computers - Read
##		Static Computer Groups - Read Update
## After the user is promoted, the computer will be removed from the static group preventing multiple uses
STATICGROUP=$8
ENCGROUP=$(curl -s -o /dev/null -w %{url_effective} --get --data-urlencode "${STATICGROUP}" "" | cut -c3-) ## URL Encoded
if [[ ${STATICGROUP} ]]; then
	XML="<?xml version=\"1.0\" encoding=\"UTF-8\" ?><computer_group><computer_deletions><computer><serial_number>${SERIAL}</serial_number></computer></computer_deletions></computer_group>"
	curl -k -H "Content-type: text/xml" -H "Authorization: Basic ${APIHASH}" "${JSSURL}JSSResource/computergroups/name/${ENCGROUP}" -d "${XML}" -X PUT
fi

##
## Make sure they aren't already an admin first.
##
isAdmin=$(dseditgroup -o checkmember -m ${currentUser} admin | awk '{print $1}')
if [[ $isAdmin == "yes" ]]; then
	osascript -e 'display dialog "You are already an admin."'
	exit 0
else
	if [[ ${ASKREASON} == "y" ]]; then
		while [[ ${REASON} == "" ]]; do
			REASON=$(osascript -e 'return the text returned  of (display dialog "Please state briefly why you need admin rights." default answer "")')
		done
	fi
	osascript -e "display dialog \"You will have administrative rights for ${TIMEMIN} minutes. DO NOT ABUSE THIS PRIVILEGE!\" buttons {\"I agree\"} default button 1"
fi

##
## Create Cleanup Pieces
##

## Create the file to track the promoted user
if [ ! -d /private/var/userToRemove ]; then
	mkdir /private/var/userToRemove
fi
echo $currentUser >> /private/var/userToRemove/user

## Create the script to demote with the launch daemon
cat << 'EOF' > /Library/Application\ Support/JAMF/removeAdmin.sh
if [[ -f /private/var/userToRemove/user ]]; then
	
	userToRemove=$(cat /private/var/userToRemove/user)
	/usr/sbin/dseditgroup -o edit -d $userToRemove -t user admin

	## If the logging option is selected, the line below gets swapped with that code
	#LOGGING#

	rm /Library/LaunchDaemons/removeAdmin.plist
	rm "/Library/Application Support/JAMF/removeAdmin.sh"
	rm -rf /private/var/userToRemove

	launchctl unload /Library/LaunchDaemons/removeAdmin.plist
fi
EOF

## If the logging option is selected, this swaps out the block above with the code listed in the
## parameter section for logging.
if [[ ${UPLOADLOG} == "y" ]]; then
    sed -i '' -e "s/#LOGGING#/${LOGCOMMAND}/" "/Library/Application Support/JAMF/removeAdmin.sh"
fi

##
##Create the plist
##
sudo defaults write /Library/LaunchDaemons/removeAdmin.plist Label -string "removeAdmin"
sudo defaults write /Library/LaunchDaemons/removeAdmin.plist ProgramArguments -array -string /bin/sh -string "/Library/Application Support/JAMF/removeAdmin.sh"
sudo defaults write /Library/LaunchDaemons/removeAdmin.plist RunAtLoad -boolean yes
sudo defaults write /Library/LaunchDaemons/removeAdmin.plist StartInterval -integer ${TIMESEC}

#Set ownership
sudo chown root:wheel /Library/LaunchDaemons/removeAdmin.plist
sudo chmod 644 /Library/LaunchDaemons/removeAdmin.plist

#Load the daemon 
launchctl load /Library/LaunchDaemons/removeAdmin.plist

##
## Give the user admin rights
##
echo "Granting ${currentUser} admin rights for ${TIMEMIN} minutes."
if [[ ${ASKREASON} == "y" ]]; then
	echo "The reason they gave was: ${REASON}"
fi
/usr/sbin/dseditgroup -o edit -a $currentUser -t user admin
STATUS=$?

## Let's double check our work and report error if not
VERIFY=$(dseditgroup -o checkmember -m ${currentUser} admin)
if [[ ${VERIFY} =~ "yes" ]]; then
	echo "VERIFIED: ${VERIFY}"
else
	echo "ERROR: ${VERIFY}"
	STATUS=1
fi

exit ${STATUS}
