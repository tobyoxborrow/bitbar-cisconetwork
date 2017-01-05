#!/bin/bash
#
# BitBar plugin to display combined connection information indicating:
# * Corporate network status
# * Internet connectivity status
# * VPN status
# * Country we appear to be from
#
# Examples:
#
# Vanilla connection from HK, no issues.
#     HK
#
# Vanilla connection from HK, disrupted Internet connectivity.
#     HK www:xx dns:ok
#
# Connected to corporate network via VPN, appearing to be from Singapore.
#     .:I:.:I:. <vpn> SG
#
# No connectivity.
#     Unknown connection www:xx dns:xx
#
# <bitbar.title>CiscoNetwork</bitbar.title>
# <bitbar.version>v1.0.0</bitbar.version>
# <bitbar.author>Toby Oxborrow</bitbar.author>
# <bitbar.author.github>tobyoxborrow</bitbar.author>
# <bitbar.desc>Display combined connection information specific for the Cisco corporate network</bitbar.desc>
#

# Create a signature of our current connection
# This is to detect if our connection has change since last time
# If not, we can skip some slow network lookups and return previous results
function connection_hash() {
    en0=$(ifconfig en0 2>/dev/null | grep inet)
    en1=$(ifconfig en1 2>/dev/null | grep inet)
    utun0=$(ifconfig utun0 2>/dev/null | grep -e '-->')
    connection_hash=$(echo "${en0}${en1}${utun0}" | /usr/bin/shasum | cut -d' ' -f1)
    echo "$connection_hash"
}

function save_connection_hash() {
    echo "$1" > /tmp/bitbar.cisconetwork.connection_hash.txt
}

function save_country() {
    echo "$1" > /tmp/bitbar.cisconetwork.last_country.txt
}

# Country detection
# ipinfo.io is super quick and allows you to pick individual fields. however,
# it only supports 1000 requests/day. that's about suitable for 16 hours.
# if ipinfo.io is not available or our api usage expires, we have a backup
# provider freegeoip.net which supports 10,000/hour but is slower
function lookup_country() {
    country=$(curl_output "ipinfo.io/country")
    if [[ $? != 1 ]]; then
        georesult=$(curl_output "freegeoip.net/csv/")
        if [[ $? == 1 ]]; then
            country=$(echo "${georesult}" | cut -d',' -f3)
        fi
    fi
    echo "$country"
}

function read_connection_hash() {
    if [[ -f /tmp/bitbar.cisconetwork.connection_hash.txt ]]; then
        cat /tmp/bitbar.cisconetwork.connection_hash.txt
    fi
}

# Find a string in the result of some GET request
function curl_findstring() {
    url=$1
    needle=$2

    output=$(curl --connect-timeout 2 --max-time 4 --silent "${url}" 2>/dev/null)
    result=$?
    if [[ $result != 0 ]]; then
        return 0
    fi

    if echo "$output" | grep --quiet "$needle"; then
        return 1
    fi

    return 0
}

# Return output (just the first line) from a GET request
function curl_output() {
    url=$1

    output=$(curl --connect-timeout 2 --max-time 4 --silent "${url}" 2>/dev/null)
    result=$?
    if [[ $result != 0 ]]; then
        return 0
    fi

    # we only need the first line for the types of requests we make
    output=$(echo "${output}" | head -1)

    # simple check for a bad response
    if echo "${output}" | grep --quiet --ignore-case "<html"; then
        return 0
    fi
    if echo "${output}" | grep --quiet --ignore-case "<!doctype"; then
        return 0
    fi
    if echo "${output}" | grep --quiet --ignore-case "rate limit exceeded"; then
        return 0
    fi
    if echo "${output}" | grep --quiet --ignore-case "try again later"; then
        return 0
    fi

    echo "$output"
    return 1
}

# Are we on the Cisco corporate network?
NETWORK='Unknown connection '
if [[ -f /etc/resolv.conf ]]; then
    # check for the cisco.com search domain added by DHCP when on the corporate
    # network or connected via corporate VPN
    if grep --quiet "cisco.com" /etc/resolv.conf; then
        NETWORK='.:I:.:I:. '
    else
        NETWORK=''
    fi
fi

# Do we have a VPN up?
# This is basic but fairly reliable.
# Could also test netstat -nr for utunX interfaces
# Known issue: Coming out of sleep OSX *sometimes* has a lingering utun0 but
# the VPN is no longer up so we will show the wrong state
VPN=''
if ifconfig utun0 >/dev/null 2>&1; then
    VPN='<vpn> '
fi

# Test connectivity. Thanks Microsoft! Thicrosoft.
# http://blog.superuser.com/2011/05/16/windows-7-network-awareness/
RESULTS=''
if [[ -f ~/bin/msncsi ]]; then
    # Use the msncsi program if available
    # https://github.com/tobyoxborrow/msncsiasm/
    ~/bin/msncsi
    r=$?
    if [[ $r == 0 ]]; then
        RESULTS='OK'
    elif [[ $r == 1 ]]; then
        RESULTS='www:xx dns:OK'
    else
        RESULTS='www:xx dns:xx'
    fi
else
    # alternative method to the msncsi program
    curl_findstring "http://www.msftncsi.com/ncsi.txt" "Microsoft NCSI"
    if [[ $? == 1 ]]; then
        RESULTS='OK'
    else
        RESULT1='www:xx'
        if dig +time=4 +tries=1 dns.msftncsi.com >/dev/null 2>&1; then
            RESULT2='dns:ok'
        else
            RESULT2='dns:xx'
        fi
        RESULTS="${RESULT1} ${RESULT2} "
    fi
fi

if [[ $RESULTS == 'OK' ]]; then
    if [[ ! -f /tmp/bitbar.cisconetwork.last_country.txt ]]; then
        country="$(lookup_country)"
        save_country "$country"

        save_connection_hash "$(connection_hash)"
    else
        last_connection_hash="$(read_connection_hash)"
        current_connection_hash="$(connection_hash)"

        if [[ $current_connection_hash == "$last_connection_hash" ]]; then
            country=$(cat /tmp/bitbar.cisconetwork.last_country.txt)
        else
            save_connection_hash "$(connection_hash)"
            country="$(lookup_country)"
            save_country "$country"
        fi
    fi

    if [[ ! -z $country ]]; then
        RESULTS="$country"
    fi
fi

echo "${NETWORK}${VPN}${RESULTS}"
