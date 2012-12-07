#!/usr/bin/env bash

# ``stack.sh`` is an opinionated OpenStack developer installation.  It
# installs and configures various combinations of **Ceilometer**, **Cinder**,
# **Glance**, **Heat**, **Horizon**, **Keystone**, **Nova**, **Quantum**
# and **Swift**

# This script allows you to specify configuration options of what git
# repositories to use, enabled services, network configuration and various
# passwords.  If you are crafty you can run the script on multiple nodes using
# shared settings for common resources (mysql, rabbitmq) and build a multi-node
# developer install.

# To keep this script simple we assume you are running on a recent **Ubuntu**
# (11.10 Oneiric or 12.04 Precise) or **Fedora** (F16 or F17) machine.  It
# should work in a VM or physical server.  Additionally we put the list of
# ``apt`` and ``rpm`` dependencies and other configuration files in this repo.

# Learn more and get the most recent version at http://devstack.org


# Keep track of the devstack directory
TOP_DIR=$(cd $(dirname "$0") && pwd)

# Import common functions
source $TOP_DIR/functions

# Determine what system we are running on.  This provides ``os_VENDOR``,
# ``os_RELEASE``, ``os_UPDATE``, ``os_PACKAGE``, ``os_CODENAME``
# and ``DISTRO``
GetDistro


# Settings
# ========

# ``stack.sh`` is customizable through setting environment variables.  If you
# want to override a setting you can set and export it::
#
#     export MYSQL_PASSWORD=anothersecret
#     ./stack.sh
#
# You can also pass options on a single line ``MYSQL_PASSWORD=simple ./stack.sh``
#
# Additionally, you can put any local variables into a ``localrc`` file::
#
#     MYSQL_PASSWORD=anothersecret
#     MYSQL_USER=hellaroot
#
# We try to have sensible defaults, so you should be able to run ``./stack.sh``
# in most cases.  ``localrc`` is not distributed with DevStack and will never
# be overwritten by a DevStack update.
#
# DevStack distributes ``stackrc`` which contains locations for the OpenStack
# repositories and branches to configure.  ``stackrc`` sources ``localrc`` to
# allow you to safely override those settings.

if [[ ! -r $TOP_DIR/stackrc ]]; then
    echo "ERROR: missing $TOP_DIR/stackrc - did you grab more than just stack.sh?"
    exit 1
fi
source $TOP_DIR/stackrc


# Proxy Settings
# --------------

# HTTP and HTTPS proxy servers are supported via the usual environment variables [1]
# ``http_proxy``, ``https_proxy`` and ``no_proxy``. They can be set in
# ``localrc`` if necessary or on the command line::
#
# [1] http://www.w3.org/Daemon/User/Proxies/ProxyClients.html
#
#     http_proxy=http://proxy.example.com:3128/ no_proxy=repo.example.net ./stack.sh

if [[ -n "$http_proxy" ]]; then
    export http_proxy=$http_proxy
fi
if [[ -n "$https_proxy" ]]; then
    export https_proxy=$https_proxy
fi
if [[ -n "$no_proxy" ]]; then
    export no_proxy=$no_proxy
fi

# Destination path for installation ``DEST``
DEST=${DEST:-/opt/stack}


# Sanity Check
# ============

# Remove services which were negated in ENABLED_SERVICES
# using the "-" prefix (e.g., "-n-vol") instead of
# calling disable_service().
disable_negated_services

# Warn users who aren't on an explicitly supported distro, but allow them to
# override check and attempt installation with ``FORCE=yes ./stack``
if [[ ! ${DISTRO} =~ (oneiric|precise|quantal|f16|f17) ]]; then
    echo "WARNING: this script has not been tested on $DISTRO"
    if [[ "$FORCE" != "yes" ]]; then
        echo "If you wish to run this script anyway run with FORCE=yes"
        exit 1
    fi
fi

# Disallow qpid on oneiric
if [ "${DISTRO}" = "oneiric" ] && is_service_enabled qpid ; then
    # Qpid was introduced in precise
    echo "You must use Ubuntu Precise or newer for Qpid support."
    exit 1
fi

# ``stack.sh`` keeps function libraries here
# Make sure ``$TOP_DIR/lib`` directory is present
if [ ! -d $TOP_DIR/lib ]; then
    echo "ERROR: missing devstack/lib"
    exit 1
fi

# ``stack.sh`` keeps the list of ``apt`` and ``rpm`` dependencies and config
# templates and other useful files in the ``files`` subdirectory
FILES=$TOP_DIR/files
if [ ! -d $FILES ]; then
    echo "ERROR: missing devstack/files"
    exit 1
fi

SCREEN_NAME=${SCREEN_NAME:-stack}
# Check to see if we are already running DevStack
if type -p screen >/dev/null && screen -ls | egrep -q "[0-9].$SCREEN_NAME"; then
    echo "You are already running a stack.sh session."
    echo "To rejoin this session type 'screen -x stack'."
    echo "To destroy this session, type './unstack.sh'."
    exit 1
fi

# Make sure we only have one rpc backend enabled.
rpc_backend_cnt=0
for svc in qpid zeromq rabbit; do
    is_service_enabled $svc &&
        ((rpc_backend_cnt++))
done
if [ "$rpc_backend_cnt" -gt 1 ]; then
    echo "ERROR: only one rpc backend may be enabled,"
    echo "       set only one of 'rabbit', 'qpid', 'zeromq'"
    echo "       via ENABLED_SERVICES."
elif [ "$rpc_backend_cnt" == 0 ]; then
    echo "ERROR: at least one rpc backend must be enabled,"
    echo "       set one of 'rabbit', 'qpid', 'zeromq'"
    echo "       via ENABLED_SERVICES."
fi
unset rpc_backend_cnt

# Make sure we only have one volume service enabled.
if is_service_enabled cinder && is_service_enabled n-vol; then
    echo "ERROR: n-vol and cinder must not be enabled at the same time"
    exit 1
fi

# Set up logging level
VERBOSE=$(trueorfalse True $VERBOSE)


# root Access
# -----------

# OpenStack is designed to be run as a non-root user; Horizon will fail to run
# as **root** since Apache will not serve content from **root** user).  If
# ``stack.sh`` is run as **root**, it automatically creates a **stack** user with
# sudo privileges and runs as that user.

if [[ $EUID -eq 0 ]]; then
    ROOTSLEEP=${ROOTSLEEP:-10}
    echo "You are running this script as root."
    echo "In $ROOTSLEEP seconds, we will create a user 'stack' and run as that user"
    sleep $ROOTSLEEP

    # Give the non-root user the ability to run as **root** via ``sudo``
    is_package_installed sudo || install_package sudo
    if ! getent group stack >/dev/null; then
        echo "Creating a group called stack"
        groupadd stack
    fi
    if ! getent passwd stack >/dev/null; then
        echo "Creating a user called stack"
        useradd -g stack -s /bin/bash -d $DEST -m stack
    fi

    echo "Giving stack user passwordless sudo privileges"
    # UEC images ``/etc/sudoers`` does not have a ``#includedir``, add one
    grep -q "^#includedir.*/etc/sudoers.d" /etc/sudoers ||
        echo "#includedir /etc/sudoers.d" >> /etc/sudoers
    ( umask 226 && echo "stack ALL=(ALL) NOPASSWD:ALL" \
        > /etc/sudoers.d/50_stack_sh )

    echo "Copying files to stack user"
    STACK_DIR="$DEST/${PWD##*/}"
    cp -r -f -T "$PWD" "$STACK_DIR"
    chown -R stack "$STACK_DIR"
    if [[ "$SHELL_AFTER_RUN" != "no" ]]; then
        exec su -c "set -e; cd $STACK_DIR; bash stack.sh; bash" stack
    else
        exec su -c "set -e; cd $STACK_DIR; bash stack.sh" stack
    fi
    exit 1
else
    # We're not **root**, make sure ``sudo`` is available
    is_package_installed sudo || die "Sudo is required.  Re-run stack.sh as root ONE TIME ONLY to set up sudo."

    # UEC images ``/etc/sudoers`` does not have a ``#includedir``, add one
    sudo grep -q "^#includedir.*/etc/sudoers.d" /etc/sudoers ||
        echo "#includedir /etc/sudoers.d" | sudo tee -a /etc/sudoers

    # Set up devstack sudoers
    TEMPFILE=`mktemp`
    echo "`whoami` ALL=(root) NOPASSWD:ALL" >$TEMPFILE
    # Some binaries might be under /sbin or /usr/sbin, so make sure sudo will
    # see them by forcing PATH
    echo "Defaults:`whoami` secure_path=/sbin:/usr/sbin:/usr/bin:/bin:/usr/local/sbin:/usr/local/bin" >> $TEMPFILE
    chmod 0440 $TEMPFILE
    sudo chown root:root $TEMPFILE
    sudo mv $TEMPFILE /etc/sudoers.d/50_stack_sh

    # Remove old file
    sudo rm -f /etc/sudoers.d/stack_sh_nova
fi

# Create the destination directory and ensure it is writable by the user
sudo mkdir -p $DEST
if [ ! -w $DEST ]; then
    sudo chown `whoami` $DEST
fi

# Set ``OFFLINE`` to ``True`` to configure ``stack.sh`` to run cleanly without
# Internet access. ``stack.sh`` must have been previously run with Internet
# access to install prerequisites and fetch repositories.
OFFLINE=`trueorfalse False $OFFLINE`

# Set ``ERROR_ON_CLONE`` to ``True`` to configure ``stack.sh`` to exit if
# the destination git repository does not exist during the ``git_clone``
# operation.
ERROR_ON_CLONE=`trueorfalse False $ERROR_ON_CLONE`

# Destination path for service data
DATA_DIR=${DATA_DIR:-${DEST}/data}
sudo mkdir -p $DATA_DIR
sudo chown `whoami` $DATA_DIR


# Common Configuration
# ====================

# Set fixed and floating range here so we can make sure not to use addresses
# from either range when attempting to guess the IP to use for the host.
# Note that setting FIXED_RANGE may be necessary when running DevStack
# in an OpenStack cloud that uses either of these address ranges internally.
FLOATING_RANGE=${FLOATING_RANGE:-172.24.4.224/28}
FIXED_RANGE=${FIXED_RANGE:-10.0.0.0/24}
FIXED_NETWORK_SIZE=${FIXED_NETWORK_SIZE:-256}
NETWORK_GATEWAY=${NETWORK_GATEWAY:-10.0.0.1}

# Find the interface used for the default route
HOST_IP_IFACE=${HOST_IP_IFACE:-$(ip route | sed -n '/^default/{ s/.*dev \(\w\+\)\s\+.*/\1/; p; }')}
# Search for an IP unless an explicit is set by ``HOST_IP`` environment variable
if [ -z "$HOST_IP" -o "$HOST_IP" == "dhcp" ]; then
    HOST_IP=""
    HOST_IPS=`LC_ALL=C ip -f inet addr show ${HOST_IP_IFACE} | awk '/inet/ {split($2,parts,"/");  print parts[1]}'`
    for IP in $HOST_IPS; do
        # Attempt to filter out IP addresses that are part of the fixed and
        # floating range. Note that this method only works if the ``netaddr``
        # python library is installed. If it is not installed, an error
        # will be printed and the first IP from the interface will be used.
        # If that is not correct set ``HOST_IP`` in ``localrc`` to the correct
        # address.
        if ! (address_in_net $IP $FIXED_RANGE || address_in_net $IP $FLOATING_RANGE); then
            HOST_IP=$IP
            break;
        fi
    done
    if [ "$HOST_IP" == "" ]; then
        echo "Could not determine host ip address."
        echo "Either localrc specified dhcp on ${HOST_IP_IFACE} or defaulted"
        exit 1
    fi
fi

# Allow the use of an alternate hostname (such as localhost/127.0.0.1) for service endpoints.
SERVICE_HOST=${SERVICE_HOST:-$HOST_IP}

# Configure services to use syslog instead of writing to individual log files
SYSLOG=`trueorfalse False $SYSLOG`
SYSLOG_HOST=${SYSLOG_HOST:-$HOST_IP}
SYSLOG_PORT=${SYSLOG_PORT:-516}

# Use color for logging output (only available if syslog is not used)
LOG_COLOR=`trueorfalse True $LOG_COLOR`

# Service startup timeout
SERVICE_TIMEOUT=${SERVICE_TIMEOUT:-60}


# Configure Projects
# ==================

# Get project function libraries
source $TOP_DIR/lib/keystone
source $TOP_DIR/lib/glance
source $TOP_DIR/lib/nova
source $TOP_DIR/lib/cinder
source $TOP_DIR/lib/n-vol
source $TOP_DIR/lib/ceilometer
source $TOP_DIR/lib/heat
source $TOP_DIR/lib/quantum

# Set the destination directories for OpenStack projects
HORIZON_DIR=$DEST/horizon
OPENSTACKCLIENT_DIR=$DEST/python-openstackclient
NOVNC_DIR=$DEST/noVNC
SWIFT_DIR=$DEST/swift
SWIFT3_DIR=$DEST/swift3
SWIFTCLIENT_DIR=$DEST/python-swiftclient
QUANTUM_DIR=$DEST/quantum
QUANTUM_CLIENT_DIR=$DEST/python-quantumclient

# Default Quantum Plugin
Q_PLUGIN=${Q_PLUGIN:-openvswitch}
# Default Quantum Port
Q_PORT=${Q_PORT:-9696}
# Default Quantum Host
Q_HOST=${Q_HOST:-localhost}
# Which Quantum API nova should use
# Default admin username
Q_ADMIN_USERNAME=${Q_ADMIN_USERNAME:-quantum}
# Default auth strategy
Q_AUTH_STRATEGY=${Q_AUTH_STRATEGY:-keystone}
# Use namespace or not
Q_USE_NAMESPACE=${Q_USE_NAMESPACE:-True}
Q_USE_ROOTWRAP=${Q_USE_ROOTWRAP=:-True}
# Meta data IP
Q_META_DATA_IP=${Q_META_DATA_IP:-$HOST_IP}

RYU_DIR=$DEST/ryu
# Ryu API Host
RYU_API_HOST=${RYU_API_HOST:-127.0.0.1}
# Ryu API Port
RYU_API_PORT=${RYU_API_PORT:-8080}
# Ryu OFP Host
RYU_OFP_HOST=${RYU_OFP_HOST:-127.0.0.1}
# Ryu OFP Port
RYU_OFP_PORT=${RYU_OFP_PORT:-6633}
# Ryu Applications
RYU_APPS=${RYU_APPS:-ryu.app.simple_isolation,ryu.app.rest}

# Name of the LVM volume group to use/create for iscsi volumes
VOLUME_GROUP=${VOLUME_GROUP:-stack-volumes}
VOLUME_NAME_PREFIX=${VOLUME_NAME_PREFIX:-volume-}
INSTANCE_NAME_PREFIX=${INSTANCE_NAME_PREFIX:-instance-}

# Generic helper to configure passwords
function read_password {
    XTRACE=$(set +o | grep xtrace)
    set +o xtrace
    var=$1; msg=$2
    pw=${!var}

    localrc=$TOP_DIR/localrc

    # If the password is not defined yet, proceed to prompt user for a password.
    if [ ! $pw ]; then
        # If there is no localrc file, create one
        if [ ! -e $localrc ]; then
            touch $localrc
        fi

        # Presumably if we got this far it can only be that our localrc is missing
        # the required password.  Prompt user for a password and write to localrc.
        echo ''
        echo '################################################################################'
        echo $msg
        echo '################################################################################'
        echo "This value will be written to your localrc file so you don't have to enter it "
        echo "again.  Use only alphanumeric characters."
        echo "If you leave this blank, a random default value will be used."
        pw=" "
        while true; do
            echo "Enter a password now:"
            read -e $var
            pw=${!var}
            [[ "$pw" = "`echo $pw | tr -cd [:alnum:]`" ]] && break
            echo "Invalid chars in password.  Try again:"
        done
        if [ ! $pw ]; then
            pw=`openssl rand -hex 10`
        fi
        eval "$var=$pw"
        echo "$var=$pw" >> $localrc
    fi
    $XTRACE
}


# Nova Network Configuration
# --------------------------

# FIXME: more documentation about why these are important options.  Also
# we should make sure we use the same variable names as the option names.

if [ "$VIRT_DRIVER" = 'xenserver' ]; then
    PUBLIC_INTERFACE_DEFAULT=eth3
    # Allow ``build_domU.sh`` to specify the flat network bridge via kernel args
    FLAT_NETWORK_BRIDGE_DEFAULT=$(grep -o 'flat_network_bridge=[[:alnum:]]*' /proc/cmdline | cut -d= -f 2 | sort -u)
    GUEST_INTERFACE_DEFAULT=eth1
else
    PUBLIC_INTERFACE_DEFAULT=br100
    FLAT_NETWORK_BRIDGE_DEFAULT=br100
    GUEST_INTERFACE_DEFAULT=eth0
fi

PUBLIC_INTERFACE=${PUBLIC_INTERFACE:-$PUBLIC_INTERFACE_DEFAULT}
NET_MAN=${NET_MAN:-FlatDHCPManager}
EC2_DMZ_HOST=${EC2_DMZ_HOST:-$SERVICE_HOST}
FLAT_NETWORK_BRIDGE=${FLAT_NETWORK_BRIDGE:-$FLAT_NETWORK_BRIDGE_DEFAULT}
VLAN_INTERFACE=${VLAN_INTERFACE:-$GUEST_INTERFACE_DEFAULT}

# Test floating pool and range are used for testing.  They are defined
# here until the admin APIs can replace nova-manage
TEST_FLOATING_POOL=${TEST_FLOATING_POOL:-test}
TEST_FLOATING_RANGE=${TEST_FLOATING_RANGE:-192.168.253.0/29}

# ``MULTI_HOST`` is a mode where each compute node runs its own network node.  This
# allows network operations and routing for a VM to occur on the server that is
# running the VM - removing a SPOF and bandwidth bottleneck.
MULTI_HOST=`trueorfalse False $MULTI_HOST`

# If you are using the FlatDHCP network mode on multiple hosts, set the
# ``FLAT_INTERFACE`` variable but make sure that the interface doesn't already
# have an IP or you risk breaking things.
#
# **DHCP Warning**:  If your flat interface device uses DHCP, there will be a
# hiccup while the network is moved from the flat interface to the flat network
# bridge.  This will happen when you launch your first instance.  Upon launch
# you will lose all connectivity to the node, and the VM launch will probably
# fail.
#
# If you are running on a single node and don't need to access the VMs from
# devices other than that node, you can set FLAT_INTERFACE=
# This will stop nova from bridging any interfaces into FLAT_NETWORK_BRIDGE.
FLAT_INTERFACE=${FLAT_INTERFACE-$GUEST_INTERFACE_DEFAULT}

## FIXME(ja): should/can we check that FLAT_INTERFACE is sane?

# Using Quantum networking:
#
# Make sure that quantum is enabled in ENABLED_SERVICES.  If you want
# to run Quantum on this host, make sure that q-svc is also in
# ENABLED_SERVICES.
#
# If you're planning to use the Quantum openvswitch plugin, set
# Q_PLUGIN to "openvswitch" and make sure the q-agt service is enabled
# in ENABLED_SERVICES.  If you're planning to use the Quantum
# linuxbridge plugin, set Q_PLUGIN to "linuxbridge" and make sure the
# q-agt service is enabled in ENABLED_SERVICES.
#
# See "Quantum Network Configuration" below for additional variables
# that must be set in localrc for connectivity across hosts with
# Quantum.
#
# With Quantum networking the NET_MAN variable is ignored.


# MySQL & (RabbitMQ or Qpid)
# --------------------------

# We configure Nova, Horizon, Glance and Keystone to use MySQL as their
# database server.  While they share a single server, each has their own
# database and tables.

# By default this script will install and configure MySQL.  If you want to
# use an existing server, you can pass in the user/password/host parameters.
# You will need to send the same ``MYSQL_PASSWORD`` to every host if you are doing
# a multi-node DevStack installation.
MYSQL_HOST=${MYSQL_HOST:-localhost}
MYSQL_USER=${MYSQL_USER:-root}
read_password MYSQL_PASSWORD "ENTER A PASSWORD TO USE FOR MYSQL."

# NOTE: Don't specify ``/db`` in this string so we can use it for multiple services
BASE_SQL_CONN=${BASE_SQL_CONN:-mysql://$MYSQL_USER:$MYSQL_PASSWORD@$MYSQL_HOST}

# Rabbit connection info
if is_service_enabled rabbit; then
    RABBIT_HOST=${RABBIT_HOST:-localhost}
    read_password RABBIT_PASSWORD "ENTER A PASSWORD TO USE FOR RABBIT."
fi


# Swift
# -----

# TODO: add logging to different location.

# Set ``SWIFT_DATA_DIR`` to the location of swift drives and objects.
# Default is the common DevStack data directory.
SWIFT_DATA_DIR=${SWIFT_DATA_DIR:-${DEST}/data/swift}

# Set ``SWIFT_CONFIG_DIR`` to the location of the configuration files.
# Default is ``/etc/swift``.
SWIFT_CONFIG_DIR=${SWIFT_CONFIG_DIR:-/etc/swift}

# DevStack will create a loop-back disk formatted as XFS to store the
# swift data. Set ``SWIFT_LOOPBACK_DISK_SIZE`` to the disk size in bytes.
# Default is 1 gigabyte.
SWIFT_LOOPBACK_DISK_SIZE=${SWIFT_LOOPBACK_DISK_SIZE:-1000000}

# The ring uses a configurable number of bits from a path’s MD5 hash as
# a partition index that designates a device. The number of bits kept
# from the hash is known as the partition power, and 2 to the partition
# power indicates the partition count. Partitioning the full MD5 hash
# ring allows other parts of the cluster to work in batches of items at
# once which ends up either more efficient or at least less complex than
# working with each item separately or the entire cluster all at once.
# By default we define 9 for the partition count (which mean 512).
SWIFT_PARTITION_POWER_SIZE=${SWIFT_PARTITION_POWER_SIZE:-9}

# Set ``SWIFT_REPLICAS`` to configure how many replicas are to be
# configured for your Swift cluster.  By default the three replicas would need a
# bit of IO and Memory on a VM you may want to lower that to 1 if you want to do
# only some quick testing.
SWIFT_REPLICAS=${SWIFT_REPLICAS:-3}

if is_service_enabled swift; then
    # If we are using swift3, we can default the s3 port to swift instead
    # of nova-objectstore
    if is_service_enabled swift3;then
        S3_SERVICE_PORT=${S3_SERVICE_PORT:-8080}
    fi
    # We only ask for Swift Hash if we have enabled swift service.
    # SWIFT_HASH is a random unique string for a swift cluster that
    # can never change.
    read_password SWIFT_HASH "ENTER A RANDOM SWIFT HASH."
fi

# Set default port for nova-objectstore
S3_SERVICE_PORT=${S3_SERVICE_PORT:-3333}


# Keystone
# --------

# The ``SERVICE_TOKEN`` is used to bootstrap the Keystone database.  It is
# just a string and is not a 'real' Keystone token.
read_password SERVICE_TOKEN "ENTER A SERVICE_TOKEN TO USE FOR THE SERVICE ADMIN TOKEN."
# Services authenticate to Identity with servicename/SERVICE_PASSWORD
read_password SERVICE_PASSWORD "ENTER A SERVICE_PASSWORD TO USE FOR THE SERVICE AUTHENTICATION."
# Horizon currently truncates usernames and passwords at 20 characters
read_password ADMIN_PASSWORD "ENTER A PASSWORD TO USE FOR HORIZON AND KEYSTONE (20 CHARS OR LESS)."

# Set the tenant for service accounts in Keystone
SERVICE_TENANT_NAME=${SERVICE_TENANT_NAME:-service}



# Horizon
# -------

# Allow overriding the default Apache user and group, default both to
# current user.
APACHE_USER=${APACHE_USER:-$USER}
APACHE_GROUP=${APACHE_GROUP:-$APACHE_USER}


# Log files
# ---------

# Draw a spinner so the user knows something is happening
function spinner()
{
    local delay=0.75
    local spinstr='|/-\'
    printf "..." >&3
    while [ true ]; do
        local temp=${spinstr#?}
        printf "[%c]" "$spinstr" >&3
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b" >&3
    done
}

# Echo text to the log file, summary log file and stdout
# echo_summary "something to say"
function echo_summary() {
    if [[ -t 3 && "$VERBOSE" != "True" ]]; then
        kill >/dev/null 2>&1 $LAST_SPINNER_PID
        if [ ! -z "$LAST_SPINNER_PID" ]; then
            printf "\b\b\bdone\n" >&3
        fi
        echo -n $@ >&6
        spinner &
        LAST_SPINNER_PID=$!
    else
        echo $@ >&6
    fi
}

# Echo text only to stdout, no log files
# echo_nolog "something not for the logs"
function echo_nolog() {
    echo $@ >&3
}

# Set up logging for ``stack.sh``
# Set ``LOGFILE`` to turn on logging
# Append '.xxxxxxxx' to the given name to maintain history
# where 'xxxxxxxx' is a representation of the date the file was created
if [[ -n "$LOGFILE" || -n "$SCREEN_LOGDIR" ]]; then
    LOGDAYS=${LOGDAYS:-7}
    TIMESTAMP_FORMAT=${TIMESTAMP_FORMAT:-"%F-%H%M%S"}
    CURRENT_LOG_TIME=$(date "+$TIMESTAMP_FORMAT")
fi

if [[ -n "$LOGFILE" ]]; then
    # First clean up old log files.  Use the user-specified ``LOGFILE``
    # as the template to search for, appending '.*' to match the date
    # we added on earlier runs.
    LOGDIR=$(dirname "$LOGFILE")
    LOGNAME=$(basename "$LOGFILE")
    mkdir -p $LOGDIR
    find $LOGDIR -maxdepth 1 -name $LOGNAME.\* -mtime +$LOGDAYS -exec rm {} \;
    LOGFILE=$LOGFILE.${CURRENT_LOG_TIME}
    SUMFILE=$LOGFILE.${CURRENT_LOG_TIME}.summary

    # Redirect output according to config
    # Copy stdout to fd 3
    exec 3>&1
    if [[ "$VERBOSE" == "True" ]]; then
        # Redirect stdout/stderr to tee to write the log file
        exec 1> >( tee "${LOGFILE}" ) 2>&1
        # Set up a second fd for output
        exec 6> >( tee "${SUMFILE}" )
    else
        # Set fd 1 and 2 to primary logfile
        exec 1> "${LOGFILE}" 2>&1
        # Set fd 6 to summary logfile and stdout
        exec 6> >( tee "${SUMFILE}" /dev/fd/3 )
    fi

    echo_summary "stack.sh log $LOGFILE"
    # Specified logfile name always links to the most recent log
    ln -sf $LOGFILE $LOGDIR/$LOGNAME
    ln -sf $SUMFILE $LOGDIR/$LOGNAME.summary
else
    # Set up output redirection without log files
    # Copy stdout to fd 3
    exec 3>&1
    if [[ "$VERBOSE" != "True" ]]; then
        # Throw away stdout and stderr
        exec 1>/dev/null 2>&1
    fi
    # Always send summary fd to original stdout
    exec 6>&3
fi

# Set up logging of screen windows
# Set ``SCREEN_LOGDIR`` to turn on logging of screen windows to the
# directory specified in ``SCREEN_LOGDIR``, we will log to the the file
# ``screen-$SERVICE_NAME-$TIMESTAMP.log`` in that dir and have a link
# ``screen-$SERVICE_NAME.log`` to the latest log file.
# Logs are kept for as long specified in ``LOGDAYS``.
if [[ -n "$SCREEN_LOGDIR" ]]; then

    # We make sure the directory is created.
    if [[ -d "$SCREEN_LOGDIR" ]]; then
        # We cleanup the old logs
        find $SCREEN_LOGDIR -maxdepth 1 -name screen-\*.log -mtime +$LOGDAYS -exec rm {} \;
    else
        mkdir -p $SCREEN_LOGDIR
    fi
fi


# Set Up Script Execution
# -----------------------

# Kill background processes on exit
trap clean EXIT
clean() {
    local r=$?
    kill >/dev/null 2>&1 $(jobs -p)
    exit $r
}


# Exit on any errors so that errors don't compound
trap failed ERR
failed() {
    local r=$?
    kill >/dev/null 2>&1 $(jobs -p)
    set +o xtrace
    [ -n "$LOGFILE" ] && echo "${0##*/} failed: full log in $LOGFILE"
    exit $r
}

# Print the commands being run so that we can see the command that triggers
# an error.  It is also useful for following along as the install occurs.
set -o xtrace


# Install Packages
# ================

# OpenStack uses a fair number of other projects.

# Install package requirements
echo_summary "Installing package prerequisites"
if [[ "$os_PACKAGE" = "deb" ]]; then
    install_package $(get_packages $FILES/apts)
else
    install_package $(get_packages $FILES/rpms)
fi

if [[ $SYSLOG != "False" ]]; then
    install_package rsyslog-relp
fi

if is_service_enabled rabbit; then
    # Install rabbitmq-server
    # the temp file is necessary due to LP: #878600
    tfile=$(mktemp)
    install_package rabbitmq-server > "$tfile" 2>&1
    cat "$tfile"
    rm -f "$tfile"
elif is_service_enabled qpid; then
    if [[ "$os_PACKAGE" = "rpm" ]]; then
        install_package qpid-cpp-server-daemon
    else
        install_package qpidd
    fi
elif is_service_enabled zeromq; then
    if [[ "$os_PACKAGE" = "rpm" ]]; then
        install_package zeromq python-zmq
    else
        install_package libzmq1 python-zmq
    fi
fi

if is_service_enabled mysql; then

    if [[ "$os_PACKAGE" = "deb" ]]; then
        # Seed configuration with mysql password so that apt-get install doesn't
        # prompt us for a password upon install.
        cat <<MYSQL_PRESEED | sudo debconf-set-selections
mysql-server-5.1 mysql-server/root_password password $MYSQL_PASSWORD
mysql-server-5.1 mysql-server/root_password_again password $MYSQL_PASSWORD
mysql-server-5.1 mysql-server/start_on_boot boolean true
MYSQL_PRESEED
    fi

    # while ``.my.cnf`` is not needed for OpenStack to function, it is useful
    # as it allows you to access the mysql databases via ``mysql nova`` instead
    # of having to specify the username/password each time.
    if [[ ! -e $HOME/.my.cnf ]]; then
        cat <<EOF >$HOME/.my.cnf
[client]
user=$MYSQL_USER
password=$MYSQL_PASSWORD
host=$MYSQL_HOST
EOF
        chmod 0600 $HOME/.my.cnf
    fi
    # Install mysql-server
    install_package mysql-server
fi

if is_service_enabled horizon; then
    if [[ "$os_PACKAGE" = "deb" ]]; then
        # Install apache2, which is NOPRIME'd
        install_package apache2 libapache2-mod-wsgi
    else
        sudo rm -f /etc/httpd/conf.d/000-*
        install_package httpd mod_wsgi
    fi
fi

if is_service_enabled q-agt; then
    if is_quantum_ovs_base_plugin "$Q_PLUGIN"; then
        # Install deps
        # FIXME add to files/apts/quantum, but don't install if not needed!
        if [[ "$os_PACKAGE" = "deb" ]]; then
            kernel_version=`cat /proc/version | cut -d " " -f3`
            install_package make fakeroot dkms openvswitch-switch openvswitch-datapath-dkms linux-headers-$kernel_version
        else
            ### FIXME(dtroyer): Find RPMs for OpenVSwitch
            echo "OpenVSwitch packages need to be located"
            # Fedora does not started OVS by default
            restart_service openvswitch
        fi
    elif [[ "$Q_PLUGIN" = "linuxbridge" ]]; then
       install_package bridge-utils
    fi
fi

if is_service_enabled swift; then
    # Install memcached for swift.
    install_package memcached
fi

TRACK_DEPENDS=${TRACK_DEPENDS:-False}

# Install python packages into a virtualenv so that we can track them
if [[ $TRACK_DEPENDS = True ]] ; then
    echo_summary "Installing Python packages into a virtualenv $DEST/.venv"
    install_package python-virtualenv

    rm -rf $DEST/.venv
    virtualenv --system-site-packages $DEST/.venv
    source $DEST/.venv/bin/activate
    $DEST/.venv/bin/pip freeze > $DEST/requires-pre-pip
fi

# Install python requirements
echo_summary "Installing Python prerequisites"
pip_install $(get_packages $FILES/pips | sort -u)


# Check Out Source
# ----------------

echo_summary "Installing OpenStack project source"

install_keystoneclient
install_glanceclient
install_novaclient

# Check out the client libs that are used most
git_clone $OPENSTACKCLIENT_REPO $OPENSTACKCLIENT_DIR $OPENSTACKCLIENT_BRANCH

# glance, swift middleware and nova api needs keystone middleware
if is_service_enabled key g-api n-api swift; then
    # unified auth system (manages accounts/tokens)
    install_keystone
fi
if is_service_enabled swift; then
    # storage service
    git_clone $SWIFT_REPO $SWIFT_DIR $SWIFT_BRANCH
    # storage service client and and Library
    git_clone $SWIFTCLIENT_REPO $SWIFTCLIENT_DIR $SWIFTCLIENT_BRANCH
    if is_service_enabled swift3; then
        # swift3 middleware to provide S3 emulation to Swift
        git_clone $SWIFT3_REPO $SWIFT3_DIR $SWIFT3_BRANCH
    fi
fi
if is_service_enabled g-api n-api; then
    # image catalog service
    install_glance
fi
if is_service_enabled nova; then
    # compute service
    install_nova
fi
if is_service_enabled n-novnc; then
    # a websockets/html5 or flash powered VNC console for vm instances
    git_clone $NOVNC_REPO $NOVNC_DIR $NOVNC_BRANCH
fi
if is_service_enabled horizon; then
    # django powered web control panel for openstack
    git_clone $HORIZON_REPO $HORIZON_DIR $HORIZON_BRANCH $HORIZON_TAG
fi
if is_service_enabled quantum; then
    git_clone $QUANTUM_CLIENT_REPO $QUANTUM_CLIENT_DIR $QUANTUM_CLIENT_BRANCH
fi
if is_service_enabled quantum; then
    # quantum
    git_clone $QUANTUM_REPO $QUANTUM_DIR $QUANTUM_BRANCH
fi
if is_service_enabled heat; then
    install_heat
fi
if is_service_enabled cinder; then
    install_cinder
fi
if is_service_enabled ceilometer; then
    install_ceilometer
fi
if is_service_enabled ryu || (is_service_enabled quantum && [[ "$Q_PLUGIN" = "ryu" ]]); then
    git_clone $RYU_REPO $RYU_DIR $RYU_BRANCH
fi

# Initialization
# ==============

echo_summary "Configuring OpenStack projects"

# Set up our checkouts so they are installed into python path
# allowing ``import nova`` or ``import glance.client``
configure_keystoneclient
configure_novaclient
setup_develop $OPENSTACKCLIENT_DIR
if is_service_enabled key g-api n-api swift; then
    configure_keystone
fi
if is_service_enabled swift; then
    setup_develop $SWIFT_DIR
    setup_develop $SWIFTCLIENT_DIR
fi
if is_service_enabled swift3; then
    setup_develop $SWIFT3_DIR
fi
if is_service_enabled g-api n-api; then
    configure_glance
fi

# Do this _after_ glance is installed to override the old binary
# TODO(dtroyer): figure out when this is no longer necessary
configure_glanceclient

if is_service_enabled nova; then
    configure_nova
fi
if is_service_enabled horizon; then
    setup_develop $HORIZON_DIR
fi
if is_service_enabled quantum; then
    setup_develop $QUANTUM_CLIENT_DIR
    setup_develop $QUANTUM_DIR
fi
if is_service_enabled heat; then
    configure_heat
fi
if is_service_enabled cinder; then
    configure_cinder
fi
if is_service_enabled ryu || (is_service_enabled quantum && [[ "$Q_PLUGIN" = "ryu" ]]); then
    setup_develop $RYU_DIR
fi

if [[ $TRACK_DEPENDS = True ]] ; then
    $DEST/.venv/bin/pip freeze > $DEST/requires-post-pip
    if ! diff -Nru $DEST/requires-pre-pip $DEST/requires-post-pip > $DEST/requires.diff ; then
        cat $DEST/requires.diff
    fi
    echo "Ran stack.sh in depend tracking mode, bailing out now"
    exit 0
fi


# Syslog
# ------

if [[ $SYSLOG != "False" ]]; then
    if [[ "$SYSLOG_HOST" = "$HOST_IP" ]]; then
        # Configure the master host to receive
        cat <<EOF >/tmp/90-stack-m.conf
\$ModLoad imrelp
\$InputRELPServerRun $SYSLOG_PORT
EOF
        sudo mv /tmp/90-stack-m.conf /etc/rsyslog.d
    else
        # Set rsyslog to send to remote host
        cat <<EOF >/tmp/90-stack-s.conf
*.*		:omrelp:$SYSLOG_HOST:$SYSLOG_PORT
EOF
        sudo mv /tmp/90-stack-s.conf /etc/rsyslog.d
    fi
    echo_summary "Starting rsyslog"
    restart_service rsyslog
fi


# Finalize queue installation
# ----------------------------

if is_service_enabled rabbit; then
    # Start rabbitmq-server
    echo_summary "Starting RabbitMQ"
    if [[ "$os_PACKAGE" = "rpm" ]]; then
        # RPM doesn't start the service
        restart_service rabbitmq-server
    fi
    # change the rabbit password since the default is "guest"
    sudo rabbitmqctl change_password guest $RABBIT_PASSWORD
elif is_service_enabled qpid; then
    echo_summary "Starting qpid"
    restart_service qpidd
fi


# Mysql
# -----

if is_service_enabled mysql; then
    echo_summary "Configuring and starting MySQL"

    if [[ "$os_PACKAGE" = "deb" ]]; then
        MY_CONF=/etc/mysql/my.cnf
        MYSQL=mysql
    else
        MY_CONF=/etc/my.cnf
        MYSQL=mysqld
    fi

    # Start mysql-server
    if [[ "$os_PACKAGE" = "rpm" ]]; then
        # RPM doesn't start the service
        start_service $MYSQL
        # Set the root password - only works the first time
        sudo mysqladmin -u root password $MYSQL_PASSWORD || true
    fi
    # Update the DB to give user ‘$MYSQL_USER’@’%’ full control of the all databases:
    sudo mysql -uroot -p$MYSQL_PASSWORD -h127.0.0.1 -e "GRANT ALL PRIVILEGES ON *.* TO '$MYSQL_USER'@'%' identified by '$MYSQL_PASSWORD';"

    # Now update ``my.cnf`` for some local needs and restart the mysql service

    # Change ‘bind-address’ from localhost (127.0.0.1) to any (0.0.0.0)
    sudo sed -i '/^bind-address/s/127.0.0.1/0.0.0.0/g' $MY_CONF

    # Set default db type to InnoDB
    if sudo grep -q "default-storage-engine" $MY_CONF; then
        # Change it
        sudo bash -c "source $TOP_DIR/functions; iniset $MY_CONF mysqld default-storage-engine InnoDB"
    else
        # Add it
        sudo sed -i -e "/^\[mysqld\]/ a \
default-storage-engine = InnoDB" $MY_CONF
    fi

    restart_service $MYSQL
fi

if [ -z "$SCREEN_HARDSTATUS" ]; then
    SCREEN_HARDSTATUS='%{= .} %-Lw%{= .}%> %n%f %t*%{= .}%+Lw%< %-=%{g}(%{d}%H/%l%{g})'
fi

# Create a new named screen to run processes in
screen -d -m -S $SCREEN_NAME -t shell -s /bin/bash
sleep 1
# Set a reasonable status bar
screen -r $SCREEN_NAME -X hardstatus alwayslastline "$SCREEN_HARDSTATUS"


# Keystone
# --------

if is_service_enabled key; then
    echo_summary "Starting Keystone"
    configure_keystone
    init_keystone
    start_keystone
    echo "Waiting for keystone to start..."
    if ! timeout $SERVICE_TIMEOUT sh -c "while ! http_proxy= curl -s $KEYSTONE_AUTH_PROTOCOL://$SERVICE_HOST:$KEYSTONE_API_PORT/v2.0/ >/dev/null; do sleep 1; done"; then
      echo "keystone did not start"
      exit 1
    fi

    # ``keystone_data.sh`` creates services, admin and demo users, and roles.
    SERVICE_ENDPOINT=$KEYSTONE_AUTH_PROTOCOL://$KEYSTONE_AUTH_HOST:$KEYSTONE_AUTH_PORT/v2.0

    ADMIN_PASSWORD=$ADMIN_PASSWORD SERVICE_TENANT_NAME=$SERVICE_TENANT_NAME SERVICE_PASSWORD=$SERVICE_PASSWORD \
    SERVICE_TOKEN=$SERVICE_TOKEN SERVICE_ENDPOINT=$SERVICE_ENDPOINT SERVICE_HOST=$SERVICE_HOST \
    S3_SERVICE_PORT=$S3_SERVICE_PORT KEYSTONE_CATALOG_BACKEND=$KEYSTONE_CATALOG_BACKEND \
    DEVSTACK_DIR=$TOP_DIR ENABLED_SERVICES=$ENABLED_SERVICES HEAT_API_CFN_PORT=$HEAT_API_CFN_PORT \
        bash -x $FILES/keystone_data.sh

    # Set up auth creds now that keystone is bootstrapped
    export OS_AUTH_URL=$SERVICE_ENDPOINT
    export OS_TENANT_NAME=admin
    export OS_USERNAME=admin
    export OS_PASSWORD=$ADMIN_PASSWORD
fi


# Horizon
# -------

# Set up the django horizon application to serve via apache/wsgi

if is_service_enabled horizon; then
    echo_summary "Configuring and starting Horizon"

    # Remove stale session database.
    rm -f $HORIZON_DIR/openstack_dashboard/local/dashboard_openstack.sqlite3

    # ``local_settings.py`` is used to override horizon default settings.
    local_settings=$HORIZON_DIR/openstack_dashboard/local/local_settings.py
    cp $FILES/horizon_settings.py $local_settings

    # Initialize the horizon database (it stores sessions and notices shown to
    # users).  The user system is external (keystone).
    cd $HORIZON_DIR
    python manage.py syncdb --noinput
    cd $TOP_DIR

    # Create an empty directory that apache uses as docroot
    sudo mkdir -p $HORIZON_DIR/.blackhole

    if [[ "$os_PACKAGE" = "deb" ]]; then
        APACHE_NAME=apache2
        APACHE_CONF=sites-available/horizon
        # Clean up the old config name
        sudo rm -f /etc/apache2/sites-enabled/000-default
        # Be a good citizen and use the distro tools here
        sudo touch /etc/$APACHE_NAME/$APACHE_CONF
        sudo a2ensite horizon
    else
        # Install httpd, which is NOPRIME'd
        APACHE_NAME=httpd
        APACHE_CONF=conf.d/horizon.conf
        sudo sed '/^Listen/s/^.*$/Listen 0.0.0.0:80/' -i /etc/httpd/conf/httpd.conf
    fi

    # Configure apache to run horizon
    sudo sh -c "sed -e \"
        s,%USER%,$APACHE_USER,g;
        s,%GROUP%,$APACHE_GROUP,g;
        s,%HORIZON_DIR%,$HORIZON_DIR,g;
        s,%APACHE_NAME%,$APACHE_NAME,g;
        s,%DEST%,$DEST,g;
    \" $FILES/apache-horizon.template >/etc/$APACHE_NAME/$APACHE_CONF"

    restart_service $APACHE_NAME
fi


# Glance
# ------

if is_service_enabled g-reg; then
    echo_summary "Configuring Glance"

    init_glance

    # Store the images in swift if enabled.
    if is_service_enabled swift; then
        iniset $GLANCE_API_CONF DEFAULT default_store swift
        iniset $GLANCE_API_CONF DEFAULT swift_store_auth_address $KEYSTONE_SERVICE_PROTOCOL://$KEYSTONE_SERVICE_HOST:$KEYSTONE_SERVICE_PORT/v2.0/
        iniset $GLANCE_API_CONF DEFAULT swift_store_user $SERVICE_TENANT_NAME:glance
        iniset $GLANCE_API_CONF DEFAULT swift_store_key $SERVICE_PASSWORD
        iniset $GLANCE_API_CONF DEFAULT swift_store_create_container_on_put True
    fi
fi


# Ryu
# ---
# Ryu is not a part of OpenStack project. Please ignore following block if
# you are not interested in Ryu.
# launch ryu manager
if is_service_enabled ryu; then
    RYU_CONF_DIR=/etc/ryu
    if [[ ! -d $RYU_CONF_DIR ]]; then
        sudo mkdir -p $RYU_CONF_DIR
    fi
    sudo chown `whoami` $RYU_CONF_DIR
    RYU_CONF=$RYU_CONF_DIR/ryu.conf
    sudo rm -rf $RYU_CONF

    cat <<EOF > $RYU_CONF
--app_lists=$RYU_APPS
--wsapi_host=$RYU_API_HOST
--wsapi_port=$RYU_API_PORT
--ofp_listen_host=$RYU_OFP_HOST
--ofp_tcp_listen_port=$RYU_OFP_PORT
--quantum_url=http://$Q_HOST:$Q_PORT
--quantum_admin_username=$Q_ADMIN_USERNAME
--quantum_admin_password=$SERVICE_PASSWORD
--quantum_admin_tenant_name=$SERVICE_TENANT_NAME
--quantum_admin_auth_url=$KEYSTONE_SERVICE_PROTOCOL://$KEYSTONE_SERVICE_HOST:$KEYSTONE_AUTH_PORT/v2.0
--quantum_auth_strategy=$Q_AUTH_STRATEGY
--quantum_controller_addr=tcp:$RYU_OFP_HOST:$RYU_OFP_PORT
EOF
    screen_it ryu "cd $RYU_DIR && $RYU_DIR/bin/ryu-manager --flagfile $RYU_CONF"
fi


# Quantum
# -------

if is_service_enabled quantum; then
    echo_summary "Configuring Quantum"
    #
    # Quantum Network Configuration
    #
    # The following variables control the Quantum openvswitch and
    # linuxbridge plugins' allocation of tenant networks and
    # availability of provider networks. If these are not configured
    # in localrc, tenant networks will be local to the host (with no
    # remote connectivity), and no physical resources will be
    # available for the allocation of provider networks.

    # To use GRE tunnels for tenant networks, set to True in
    # localrc. GRE tunnels are only supported by the openvswitch
    # plugin, and currently only on Ubuntu.
    ENABLE_TENANT_TUNNELS=${ENABLE_TENANT_TUNNELS:-False}

    # If using GRE tunnels for tenant networks, specify the range of
    # tunnel IDs from which tenant networks are allocated. Can be
    # overriden in localrc in necesssary.
    TENANT_TUNNEL_RANGES=${TENANT_TUNNEL_RANGE:-1:1000}

    # To use VLANs for tenant networks, set to True in localrc. VLANs
    # are supported by the openvswitch and linuxbridge plugins, each
    # requiring additional configuration described below.
    ENABLE_TENANT_VLANS=${ENABLE_TENANT_VLANS:-False}

    # If using VLANs for tenant networks, set in localrc to specify
    # the range of VLAN VIDs from which tenant networks are
    # allocated. An external network switch must be configured to
    # trunk these VLANs between hosts for multi-host connectivity.
    #
    # Example: TENANT_VLAN_RANGE=1000:1999
    TENANT_VLAN_RANGE=${TENANT_VLAN_RANGE:-}

    # If using VLANs for tenant networks, or if using flat or VLAN
    # provider networks, set in localrc to the name of the physical
    # network, and also configure OVS_PHYSICAL_BRIDGE for the
    # openvswitch agent or LB_PHYSICAL_INTERFACE for the linuxbridge
    # agent, as described below.
    #
    # Example: PHYSICAL_NETWORK=default
    PHYSICAL_NETWORK=${PHYSICAL_NETWORK:-}

    # With the openvswitch plugin, if using VLANs for tenant networks,
    # or if using flat or VLAN provider networks, set in localrc to
    # the name of the OVS bridge to use for the physical network. The
    # bridge will be created if it does not already exist, but a
    # physical interface must be manually added to the bridge as a
    # port for external connectivity.
    #
    # Example: OVS_PHYSICAL_BRIDGE=br-eth1
    OVS_PHYSICAL_BRIDGE=${OVS_PHYSICAL_BRIDGE:-}

    # With the linuxbridge plugin, if using VLANs for tenant networks,
    # or if using flat or VLAN provider networks, set in localrc to
    # the name of the network interface to use for the physical
    # network.
    #
    # Example: LB_PHYSICAL_INTERFACE=eth1
    LB_PHYSICAL_INTERFACE=${LB_PHYSICAL_INTERFACE:-}

    # With the openvswitch plugin, set to True in localrc to enable
    # provider GRE tunnels when ENABLE_TENANT_TUNNELS is False.
    #
    # Example: OVS_ENABLE_TUNNELING=True
    OVS_ENABLE_TUNNELING=${OVS_ENABLE_TUNNELING:-$ENABLE_TENANT_TUNNELS}

    # Put config files in ``/etc/quantum`` for everyone to find
    if [[ ! -d /etc/quantum ]]; then
        sudo mkdir -p /etc/quantum
    fi
    sudo chown `whoami` /etc/quantum

    if [[ "$Q_PLUGIN" = "openvswitch" ]]; then
        Q_PLUGIN_CONF_PATH=etc/quantum/plugins/openvswitch
        Q_PLUGIN_CONF_FILENAME=ovs_quantum_plugin.ini
        Q_DB_NAME="ovs_quantum"
        Q_PLUGIN_CLASS="quantum.plugins.openvswitch.ovs_quantum_plugin.OVSQuantumPluginV2"
    elif [[ "$Q_PLUGIN" = "linuxbridge" ]]; then
        Q_PLUGIN_CONF_PATH=etc/quantum/plugins/linuxbridge
        Q_PLUGIN_CONF_FILENAME=linuxbridge_conf.ini
        Q_DB_NAME="quantum_linux_bridge"
        Q_PLUGIN_CLASS="quantum.plugins.linuxbridge.lb_quantum_plugin.LinuxBridgePluginV2"
    elif [[ "$Q_PLUGIN" = "ryu" ]]; then
        Q_PLUGIN_CONF_PATH=etc/quantum/plugins/ryu
        Q_PLUGIN_CONF_FILENAME=ryu.ini
        Q_DB_NAME="ovs_quantum"
        Q_PLUGIN_CLASS="quantum.plugins.ryu.ryu_quantum_plugin.RyuQuantumPluginV2"
    else
        echo "Unknown Quantum plugin '$Q_PLUGIN'.. exiting"
        exit 1
    fi

    # If needed, move config file from ``$QUANTUM_DIR/etc/quantum`` to ``/etc/quantum``
    mkdir -p /$Q_PLUGIN_CONF_PATH
    Q_PLUGIN_CONF_FILE=$Q_PLUGIN_CONF_PATH/$Q_PLUGIN_CONF_FILENAME
    cp $QUANTUM_DIR/$Q_PLUGIN_CONF_FILE /$Q_PLUGIN_CONF_FILE

    iniset /$Q_PLUGIN_CONF_FILE DATABASE sql_connection mysql:\/\/$MYSQL_USER:$MYSQL_PASSWORD@$MYSQL_HOST\/$Q_DB_NAME?charset=utf8

    Q_CONF_FILE=/etc/quantum/quantum.conf
    cp $QUANTUM_DIR/etc/quantum.conf $Q_CONF_FILE
    Q_RR_CONF_FILE=/etc/quantum/rootwrap.conf
    if [[ "$Q_USE_ROOTWRAP" == "False" ]]; then
        Q_RR_COMMAND="sudo"
    else
        Q_RR_COMMAND="sudo $QUANTUM_DIR/bin/quantum-rootwrap $Q_RR_CONF_FILE"
    fi
    cp -p $QUANTUM_DIR/etc/rootwrap.conf $Q_RR_CONF_FILE

    # Copy over the config and filter bits
    Q_CONF_ROOTWRAP_D=/etc/quantum/rootwrap.d
    mkdir -p $Q_CONF_ROOTWRAP_D
    cp -pr $QUANTUM_DIR/etc/quantum/rootwrap.d/* $Q_CONF_ROOTWRAP_D/
fi

# Quantum service (for controller node)
if is_service_enabled q-svc; then
    Q_API_PASTE_FILE=/etc/quantum/api-paste.ini
    Q_POLICY_FILE=/etc/quantum/policy.json

    cp $QUANTUM_DIR/etc/api-paste.ini $Q_API_PASTE_FILE
    cp $QUANTUM_DIR/etc/policy.json $Q_POLICY_FILE

    if is_service_enabled mysql; then
            mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e "DROP DATABASE IF EXISTS $Q_DB_NAME;"
            mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e "CREATE DATABASE IF NOT EXISTS $Q_DB_NAME CHARACTER SET utf8;"
        else
            echo "mysql must be enabled in order to use the $Q_PLUGIN Quantum plugin."
            exit 1
    fi

    # Update either configuration file with plugin
    iniset $Q_CONF_FILE DEFAULT core_plugin $Q_PLUGIN_CLASS

    iniset $Q_CONF_FILE DEFAULT auth_strategy $Q_AUTH_STRATEGY
    quantum_setup_keystone $Q_API_PASTE_FILE filter:authtoken

    # Configure plugin
    if [[ "$Q_PLUGIN" = "openvswitch" ]]; then
        if [[ "$ENABLE_TENANT_TUNNELS" = "True" ]]; then
            iniset /$Q_PLUGIN_CONF_FILE OVS tenant_network_type gre
            iniset /$Q_PLUGIN_CONF_FILE OVS tunnel_id_ranges $TENANT_TUNNEL_RANGES
        elif [[ "$ENABLE_TENANT_VLANS" = "True" ]]; then
            iniset /$Q_PLUGIN_CONF_FILE OVS tenant_network_type vlan
        else
            echo "WARNING - The openvswitch plugin is using local tenant networks, with no connectivity between hosts."
        fi

        # Override OVS_VLAN_RANGES and OVS_BRIDGE_MAPPINGS in localrc
        # for more complex physical network configurations.
        if [[ "$OVS_VLAN_RANGES" = "" ]] && [[ "$PHYSICAL_NETWORK" != "" ]]; then
            OVS_VLAN_RANGES=$PHYSICAL_NETWORK
            if [[ "$TENANT_VLAN_RANGE" != "" ]]; then
                OVS_VLAN_RANGES=$OVS_VLAN_RANGES:$TENANT_VLAN_RANGE
            fi
        fi
        if [[ "$OVS_VLAN_RANGES" != "" ]]; then
            iniset /$Q_PLUGIN_CONF_FILE OVS network_vlan_ranges $OVS_VLAN_RANGES
        fi

        # Enable tunnel networks if selected
        if [[ $OVS_ENABLE_TUNNELING = "True" ]]; then
            iniset /$Q_PLUGIN_CONF_FILE OVS enable_tunneling True
        fi
    elif [[ "$Q_PLUGIN" = "linuxbridge" ]]; then
        if [[ "$ENABLE_TENANT_VLANS" = "True" ]]; then
            iniset /$Q_PLUGIN_CONF_FILE VLANS tenant_network_type vlan
        else
            echo "WARNING - The linuxbridge plugin is using local tenant networks, with no connectivity between hosts."
        fi

        # Override LB_VLAN_RANGES and LB_INTERFACE_MAPPINGS in localrc
        # for more complex physical network configurations.
        if [[ "$LB_VLAN_RANGES" = "" ]] && [[ "$PHYSICAL_NETWORK" != "" ]]; then
            LB_VLAN_RANGES=$PHYSICAL_NETWORK
            if [[ "$TENANT_VLAN_RANGE" != "" ]]; then
                LB_VLAN_RANGES=$LB_VLAN_RANGES:$TENANT_VLAN_RANGE
            fi
        fi
        if [[ "$LB_VLAN_RANGES" != "" ]]; then
            iniset /$Q_PLUGIN_CONF_FILE VLANS network_vlan_ranges $LB_VLAN_RANGES
        fi
    elif [[ "$Q_PLUGIN" = "ryu" ]]; then
        iniset /$Q_PLUGIN_CONF_FILE OVS openflow_rest_api $RYU_API_HOST:$RYU_API_PORT
    fi
fi

# Quantum agent (for compute nodes)
if is_service_enabled q-agt; then
    # Configure agent for plugin
    if [[ "$Q_PLUGIN" = "openvswitch" ]]; then
        # Setup integration bridge
        OVS_BRIDGE=${OVS_BRIDGE:-br-int}
        quantum_setup_ovs_bridge $OVS_BRIDGE

        # Setup agent for tunneling
        if [[ "$OVS_ENABLE_TUNNELING" = "True" ]]; then
            # Verify tunnels are supported
            # REVISIT - also check kernel module support for GRE and patch ports
            OVS_VERSION=`ovs-vsctl --version | head -n 1 | awk '{print $4;}'`
            if [ $OVS_VERSION \< "1.4" ] && ! is_service_enabled q-svc ; then
                echo "You are running OVS version $OVS_VERSION."
                echo "OVS 1.4+ is required for tunneling between multiple hosts."
                exit 1
            fi
            iniset /$Q_PLUGIN_CONF_FILE OVS enable_tunneling True
            iniset /$Q_PLUGIN_CONF_FILE OVS local_ip $HOST_IP
        fi

        # Setup physical network bridge mappings.  Override
        # OVS_VLAN_RANGES and OVS_BRIDGE_MAPPINGS in localrc for more
        # complex physical network configurations.
        if [[ "$OVS_BRIDGE_MAPPINGS" = "" ]] && [[ "$PHYSICAL_NETWORK" != "" ]] && [[ "$OVS_PHYSICAL_BRIDGE" != "" ]]; then
            OVS_BRIDGE_MAPPINGS=$PHYSICAL_NETWORK:$OVS_PHYSICAL_BRIDGE

            # Configure bridge manually with physical interface as port for multi-node
            sudo ovs-vsctl --no-wait -- --may-exist add-br $OVS_PHYSICAL_BRIDGE
        fi
        if [[ "$OVS_BRIDGE_MAPPINGS" != "" ]]; then
            iniset /$Q_PLUGIN_CONF_FILE OVS bridge_mappings $OVS_BRIDGE_MAPPINGS
        fi
        AGENT_BINARY="$QUANTUM_DIR/bin/quantum-openvswitch-agent"
    elif [[ "$Q_PLUGIN" = "linuxbridge" ]]; then
        # Setup physical network interface mappings.  Override
        # LB_VLAN_RANGES and LB_INTERFACE_MAPPINGS in localrc for more
        # complex physical network configurations.
        if [[ "$LB_INTERFACE_MAPPINGS" = "" ]] && [[ "$PHYSICAL_NETWORK" != "" ]] && [[ "$LB_PHYSICAL_INTERFACE" != "" ]]; then
            LB_INTERFACE_MAPPINGS=$PHYSICAL_NETWORK:$LB_PHYSICAL_INTERFACE
        fi
        if [[ "$LB_INTERFACE_MAPPINGS" != "" ]]; then
            iniset /$Q_PLUGIN_CONF_FILE LINUX_BRIDGE physical_interface_mappings $LB_INTERFACE_MAPPINGS
        fi
        AGENT_BINARY="$QUANTUM_DIR/bin/quantum-linuxbridge-agent"
    elif [[ "$Q_PLUGIN" = "ryu" ]]; then
        # Set up integration bridge
        OVS_BRIDGE=${OVS_BRIDGE:-br-int}
        quantum_setup_ovs_bridge $OVS_BRIDGE
        if [ -n "$RYU_INTERNAL_INTERFACE" ]; then
            sudo ovs-vsctl --no-wait -- --may-exist add-port $OVS_BRIDGE $RYU_INTERNAL_INTERFACE
        fi
        iniset /$Q_PLUGIN_CONF_FILE OVS integration_bridge $OVS_BRIDGE
        AGENT_BINARY="$QUANTUM_DIR/quantum/plugins/ryu/agent/ryu_quantum_agent.py"
    fi
    # Update config w/rootwrap
    iniset /$Q_PLUGIN_CONF_FILE AGENT root_helper "$Q_RR_COMMAND"
fi

# Quantum DHCP
if is_service_enabled q-dhcp; then
    AGENT_DHCP_BINARY="$QUANTUM_DIR/bin/quantum-dhcp-agent"

    Q_DHCP_CONF_FILE=/etc/quantum/dhcp_agent.ini

    cp $QUANTUM_DIR/etc/dhcp_agent.ini $Q_DHCP_CONF_FILE

    # Set verbose
    iniset $Q_DHCP_CONF_FILE DEFAULT verbose True
    # Set debug
    iniset $Q_DHCP_CONF_FILE DEFAULT debug True
    iniset $Q_DHCP_CONF_FILE DEFAULT use_namespaces $Q_USE_NAMESPACE

    quantum_setup_keystone $Q_DHCP_CONF_FILE DEFAULT set_auth_url

    # Update config w/rootwrap
    iniset $Q_DHCP_CONF_FILE DEFAULT root_helper "$Q_RR_COMMAND"

    if [[ "$Q_PLUGIN" = "openvswitch" ]]; then
        iniset $Q_DHCP_CONF_FILE DEFAULT interface_driver quantum.agent.linux.interface.OVSInterfaceDriver
    elif [[ "$Q_PLUGIN" = "linuxbridge" ]]; then
        iniset $Q_DHCP_CONF_FILE DEFAULT interface_driver quantum.agent.linux.interface.BridgeInterfaceDriver
    elif [[ "$Q_PLUGIN" = "ryu" ]]; then
        iniset $Q_DHCP_CONF_FILE DEFAULT interface_driver quantum.agent.linux.interface.OVSInterfaceDriver
        iniset $Q_DHCP_CONF_FILE DEFAULT ovs_use_veth True
    fi
fi

# Quantum L3
if is_service_enabled q-l3; then
    AGENT_L3_BINARY="$QUANTUM_DIR/bin/quantum-l3-agent"
    PUBLIC_BRIDGE=${PUBLIC_BRIDGE:-br-ex}
    Q_L3_CONF_FILE=/etc/quantum/l3_agent.ini

    cp $QUANTUM_DIR/etc/l3_agent.ini $Q_L3_CONF_FILE

    # Set verbose
    iniset $Q_L3_CONF_FILE DEFAULT verbose True
    # Set debug
    iniset $Q_L3_CONF_FILE DEFAULT debug True

    iniset $Q_L3_CONF_FILE DEFAULT metadata_ip $Q_META_DATA_IP
    iniset $Q_L3_CONF_FILE DEFAULT use_namespaces $Q_USE_NAMESPACE

    iniset $Q_L3_CONF_FILE DEFAULT root_helper "$Q_RR_COMMAND"

    quantum_setup_keystone $Q_L3_CONF_FILE DEFAULT set_auth_url
    if [[ "$Q_PLUGIN" == "openvswitch" ]]; then
        iniset $Q_L3_CONF_FILE DEFAULT interface_driver quantum.agent.linux.interface.OVSInterfaceDriver
        iniset $Q_L3_CONF_FILE DEFAULT external_network_bridge $PUBLIC_BRIDGE
        # Set up external bridge
        quantum_setup_external_bridge $PUBLIC_BRIDGE
    elif [[ "$Q_PLUGIN" = "linuxbridge" ]]; then
        iniset $Q_L3_CONF_FILE DEFAULT interface_driver quantum.agent.linux.interface.BridgeInterfaceDriver
        iniset $Q_L3_CONF_FILE DEFAULT external_network_bridge ''
    elif [[ "$Q_PLUGIN" = "ryu" ]]; then
        iniset $Q_L3_CONF_FILE DEFAULT interface_driver quantum.agent.linux.interface.OVSInterfaceDriver
        iniset $Q_L3_CONF_FILE DEFAULT ovs_use_veth True
        iniset $Q_L3_CONF_FILE DEFAULT external_network_bridge $PUBLIC_BRIDGE
        iniset $Q_L3_CONF_FILE DEFAULT ryu_api_host $RYU_API_HOST:$RYU_API_PORT
        # Set up external bridge
        quantum_setup_external_bridge $PUBLIC_BRIDGE
    fi
fi

# Quantum RPC support - must be updated prior to starting any of the services
if is_service_enabled quantum; then
    iniset $Q_CONF_FILE DEFAULT control_exchange quantum
    if is_service_enabled qpid ; then
        iniset $Q_CONF_FILE DEFAULT rpc_backend quantum.openstack.common.rpc.impl_qpid
    elif is_service_enabled zeromq; then
        iniset $Q_CONF_FILE DEFAULT rpc_backend quantum.openstack.common.rpc.impl_zmq
    elif [ -n "$RABBIT_HOST" ] &&  [ -n "$RABBIT_PASSWORD" ]; then
        iniset $Q_CONF_FILE DEFAULT rabbit_host $RABBIT_HOST
        iniset $Q_CONF_FILE DEFAULT rabbit_password $RABBIT_PASSWORD
    fi
fi

# Nova
# ----

if is_service_enabled nova; then
    echo_summary "Configuring Nova"
    configure_nova
fi

if is_service_enabled n-net q-dhcp; then
    # Delete traces of nova networks from prior runs
    sudo killall dnsmasq || true
    clean_iptables
    rm -rf $NOVA_STATE_PATH/networks
    mkdir -p $NOVA_STATE_PATH/networks

    # Force IP forwarding on, just on case
    sudo sysctl -w net.ipv4.ip_forward=1
fi


# Storage Service
# ---------------

if is_service_enabled swift; then
    echo_summary "Configuring Swift"

    # Make sure to kill all swift processes first
    swift-init all stop || true

    # First do a bit of setup by creating the directories and
    # changing the permissions so we can run it as our user.

    USER_GROUP=$(id -g)
    sudo mkdir -p ${SWIFT_DATA_DIR}/drives
    sudo chown -R $USER:${USER_GROUP} ${SWIFT_DATA_DIR}

    # Create a loopback disk and format it to XFS.
    if [[ -e ${SWIFT_DATA_DIR}/drives/images/swift.img ]]; then
        if egrep -q ${SWIFT_DATA_DIR}/drives/sdb1 /proc/mounts; then
            sudo umount ${SWIFT_DATA_DIR}/drives/sdb1
        fi
    else
        mkdir -p  ${SWIFT_DATA_DIR}/drives/images
        sudo touch  ${SWIFT_DATA_DIR}/drives/images/swift.img
        sudo chown $USER: ${SWIFT_DATA_DIR}/drives/images/swift.img

        dd if=/dev/zero of=${SWIFT_DATA_DIR}/drives/images/swift.img \
            bs=1024 count=0 seek=${SWIFT_LOOPBACK_DISK_SIZE}
    fi

    # Make a fresh XFS filesystem
    mkfs.xfs -f -i size=1024  ${SWIFT_DATA_DIR}/drives/images/swift.img

    # Mount the disk with mount options to make it as efficient as possible
    mkdir -p ${SWIFT_DATA_DIR}/drives/sdb1
    if ! egrep -q ${SWIFT_DATA_DIR}/drives/sdb1 /proc/mounts; then
        sudo mount -t xfs -o loop,noatime,nodiratime,nobarrier,logbufs=8  \
            ${SWIFT_DATA_DIR}/drives/images/swift.img ${SWIFT_DATA_DIR}/drives/sdb1
    fi

    # Create a link to the above mount
    for x in $(seq ${SWIFT_REPLICAS}); do
        sudo ln -sf ${SWIFT_DATA_DIR}/drives/sdb1/$x ${SWIFT_DATA_DIR}/$x; done

    # Create all of the directories needed to emulate a few different servers
    for x in $(seq ${SWIFT_REPLICAS}); do
            drive=${SWIFT_DATA_DIR}/drives/sdb1/${x}
            node=${SWIFT_DATA_DIR}/${x}/node
            node_device=${node}/sdb1
            [[ -d $node ]] && continue
            [[ -d $drive ]] && continue
            sudo install -o ${USER} -g $USER_GROUP -d $drive
            sudo install -o ${USER} -g $USER_GROUP -d $node_device
            sudo chown -R $USER: ${node}
    done

   sudo mkdir -p ${SWIFT_CONFIG_DIR}/{object,container,account}-server /var/run/swift
   sudo chown -R $USER: ${SWIFT_CONFIG_DIR} /var/run/swift

    if [[ "$SWIFT_CONFIG_DIR" != "/etc/swift" ]]; then
        # Some swift tools are hard-coded to use ``/etc/swift`` and are apparently not going to be fixed.
        # Create a symlink if the config dir is moved
        sudo ln -sf ${SWIFT_CONFIG_DIR} /etc/swift
    fi

    # Swift use rsync to synchronize between all the different
    # partitions (which make more sense when you have a multi-node
    # setup) we configure it with our version of rsync.
    sed -e "
        s/%GROUP%/${USER_GROUP}/;
        s/%USER%/$USER/;
        s,%SWIFT_DATA_DIR%,$SWIFT_DATA_DIR,;
    " $FILES/swift/rsyncd.conf | sudo tee /etc/rsyncd.conf
    if [[ "$os_PACKAGE" = "deb" ]]; then
        sudo sed -i '/^RSYNC_ENABLE=false/ { s/false/true/ }' /etc/default/rsync
    else
        sudo sed -i '/disable *= *yes/ { s/yes/no/ }' /etc/xinetd.d/rsync
    fi

    if is_service_enabled swift3;then
        swift_auth_server="s3token "
    fi

    # By default Swift will be installed with the tempauth middleware
    # which has some default username and password if you have
    # configured keystone it will checkout the directory.
    if is_service_enabled key; then
        swift_auth_server+="authtoken keystoneauth"
    else
        swift_auth_server=tempauth
    fi

    SWIFT_CONFIG_PROXY_SERVER=${SWIFT_CONFIG_DIR}/proxy-server.conf
    cp ${SWIFT_DIR}/etc/proxy-server.conf-sample ${SWIFT_CONFIG_PROXY_SERVER}

    iniuncomment ${SWIFT_CONFIG_PROXY_SERVER} DEFAULT user
    iniset ${SWIFT_CONFIG_PROXY_SERVER} DEFAULT user ${USER}

    iniuncomment ${SWIFT_CONFIG_PROXY_SERVER} DEFAULT swift_dir
    iniset ${SWIFT_CONFIG_PROXY_SERVER} DEFAULT swift_dir ${SWIFT_CONFIG_DIR}

    iniuncomment ${SWIFT_CONFIG_PROXY_SERVER} DEFAULT workers
    iniset ${SWIFT_CONFIG_PROXY_SERVER} DEFAULT workers 1

    iniuncomment ${SWIFT_CONFIG_PROXY_SERVER} DEFAULT log_level
    iniset ${SWIFT_CONFIG_PROXY_SERVER} DEFAULT log_level DEBUG

    iniuncomment ${SWIFT_CONFIG_PROXY_SERVER} DEFAULT bind_port
    iniset ${SWIFT_CONFIG_PROXY_SERVER} DEFAULT bind_port ${SWIFT_DEFAULT_BIND_PORT:-8080}

    # Only enable Swift3 if we have it enabled in ENABLED_SERVICES
    is_service_enabled swift3 && swift3=swift3 || swift3=""

    iniset ${SWIFT_CONFIG_PROXY_SERVER} pipeline:main pipeline "catch_errors healthcheck cache ratelimit ${swift3} ${swift_auth_server} proxy-logging proxy-server"

    iniset ${SWIFT_CONFIG_PROXY_SERVER} app:proxy-server account_autocreate true

    # Configure Keystone
    sed -i '/^# \[filter:authtoken\]/,/^# \[filter:keystoneauth\]$/ s/^#[ \t]*//' ${SWIFT_CONFIG_PROXY_SERVER}
    iniset ${SWIFT_CONFIG_PROXY_SERVER} filter:authtoken auth_host $KEYSTONE_AUTH_HOST
    iniset ${SWIFT_CONFIG_PROXY_SERVER} filter:authtoken auth_port $KEYSTONE_AUTH_PORT
    iniset ${SWIFT_CONFIG_PROXY_SERVER} filter:authtoken auth_protocol $KEYSTONE_AUTH_PROTOCOL
    iniset ${SWIFT_CONFIG_PROXY_SERVER} filter:authtoken auth_uri $KEYSTONE_SERVICE_PROTOCOL://$KEYSTONE_SERVICE_HOST:$KEYSTONE_SERVICE_PORT/
    iniset ${SWIFT_CONFIG_PROXY_SERVER} filter:authtoken admin_tenant_name $SERVICE_TENANT_NAME
    iniset ${SWIFT_CONFIG_PROXY_SERVER} filter:authtoken admin_user swift
    iniset ${SWIFT_CONFIG_PROXY_SERVER} filter:authtoken admin_password $SERVICE_PASSWORD

    iniuncomment ${SWIFT_CONFIG_PROXY_SERVER} filter:keystoneauth use
    iniuncomment ${SWIFT_CONFIG_PROXY_SERVER} filter:keystoneauth operator_roles
    iniset ${SWIFT_CONFIG_PROXY_SERVER} filter:keystoneauth operator_roles "Member, admin"

    if is_service_enabled swift3; then
        cat <<EOF >>${SWIFT_CONFIG_PROXY_SERVER}
# NOTE(chmou): s3token middleware is not updated yet to use only
# username and password.
[filter:s3token]
paste.filter_factory = keystone.middleware.s3_token:filter_factory
auth_port = ${KEYSTONE_AUTH_PORT}
auth_host = ${KEYSTONE_AUTH_HOST}
auth_protocol = ${KEYSTONE_AUTH_PROTOCOL}
auth_token = ${SERVICE_TOKEN}
admin_token = ${SERVICE_TOKEN}

[filter:swift3]
use = egg:swift3#swift3
EOF
    fi

    cp ${SWIFT_DIR}/etc/swift.conf-sample ${SWIFT_CONFIG_DIR}/swift.conf
    iniset ${SWIFT_CONFIG_DIR}/swift.conf swift-hash swift_hash_path_suffix ${SWIFT_HASH}

    # This function generates an object/account/proxy configuration
    # emulating 4 nodes on different ports
    function generate_swift_configuration() {
        local server_type=$1
        local bind_port=$2
        local log_facility=$3
        local node_number
        local swift_node_config

        for node_number in $(seq ${SWIFT_REPLICAS}); do
            node_path=${SWIFT_DATA_DIR}/${node_number}
            swift_node_config=${SWIFT_CONFIG_DIR}/${server_type}-server/${node_number}.conf

            cp ${SWIFT_DIR}/etc/${server_type}-server.conf-sample ${swift_node_config}

            iniuncomment ${swift_node_config} DEFAULT user
            iniset ${swift_node_config} DEFAULT user ${USER}

            iniuncomment ${swift_node_config} DEFAULT bind_port
            iniset ${swift_node_config} DEFAULT bind_port ${bind_port}

            iniuncomment ${swift_node_config} DEFAULT swift_dir
            iniset ${swift_node_config} DEFAULT swift_dir ${SWIFT_CONFIG_DIR}

            iniuncomment ${swift_node_config} DEFAULT devices
            iniset ${swift_node_config} DEFAULT devices ${node_path}

            iniuncomment ${swift_node_config} DEFAULT log_facility
            iniset ${swift_node_config} DEFAULT log_facility LOG_LOCAL${log_facility}

            iniuncomment ${swift_node_config} DEFAULT mount_check
            iniset ${swift_node_config} DEFAULT mount_check false

            iniuncomment ${swift_node_config} ${server_type}-replicator vm_test_mode
            iniset ${swift_node_config} ${server_type}-replicator vm_test_mode yes

            bind_port=$(( ${bind_port} + 10 ))
            log_facility=$(( ${log_facility} + 1 ))
        done
    }
    generate_swift_configuration object 6010 2
    generate_swift_configuration container 6011 2
    generate_swift_configuration account 6012 2

    # Specific configuration for swift for rsyslog. See
    # ``/etc/rsyslog.d/10-swift.conf`` for more info.
    swift_log_dir=${SWIFT_DATA_DIR}/logs
    rm -rf ${swift_log_dir}
    mkdir -p ${swift_log_dir}/hourly
    sudo chown -R $USER:adm ${swift_log_dir}
    sed "s,%SWIFT_LOGDIR%,${swift_log_dir}," $FILES/swift/rsyslog.conf | sudo \
        tee /etc/rsyslog.d/10-swift.conf
    restart_service rsyslog

    # This is where we create three different rings for swift with
    # different object servers binding on different ports.
    pushd ${SWIFT_CONFIG_DIR} >/dev/null && {

        rm -f *.builder *.ring.gz backups/*.builder backups/*.ring.gz

        port_number=6010
        swift-ring-builder object.builder create ${SWIFT_PARTITION_POWER_SIZE} ${SWIFT_REPLICAS} 1
        for x in $(seq ${SWIFT_REPLICAS}); do
            swift-ring-builder object.builder add z${x}-127.0.0.1:${port_number}/sdb1 1
            port_number=$[port_number + 10]
        done
        swift-ring-builder object.builder rebalance

        port_number=6011
        swift-ring-builder container.builder create ${SWIFT_PARTITION_POWER_SIZE} ${SWIFT_REPLICAS} 1
        for x in $(seq ${SWIFT_REPLICAS}); do
            swift-ring-builder container.builder add z${x}-127.0.0.1:${port_number}/sdb1 1
            port_number=$[port_number + 10]
        done
        swift-ring-builder container.builder rebalance

        port_number=6012
        swift-ring-builder account.builder create ${SWIFT_PARTITION_POWER_SIZE} ${SWIFT_REPLICAS} 1
        for x in $(seq ${SWIFT_REPLICAS}); do
            swift-ring-builder account.builder add z${x}-127.0.0.1:${port_number}/sdb1 1
            port_number=$[port_number + 10]
        done
        swift-ring-builder account.builder rebalance

    } && popd >/dev/null

   # Start rsync
    if [[ "$os_PACKAGE" = "deb" ]]; then
        sudo /etc/init.d/rsync restart || :
    else
        sudo systemctl start xinetd.service
    fi

   # First spawn all the swift services then kill the
   # proxy service so we can run it in foreground in screen.
   # ``swift-init ... {stop|restart}`` exits with '1' if no servers are running,
   # ignore it just in case
   swift-init all restart || true
   swift-init proxy stop || true

   unset s swift_hash swift_auth_server
fi


# Volume Service
# --------------

if is_service_enabled cinder; then
    echo_summary "Configuring Cinder"
    init_cinder
elif is_service_enabled n-vol; then
    echo_summary "Configuring Nova volumes"
    init_nvol
fi

if is_service_enabled nova; then
    echo_summary "Configuring Nova"
    init_nova
fi

# Additional Nova configuration that is dependent on other services
if is_service_enabled quantum; then
    add_nova_opt "network_api_class=nova.network.quantumv2.api.API"
    add_nova_opt "quantum_admin_username=$Q_ADMIN_USERNAME"
    add_nova_opt "quantum_admin_password=$SERVICE_PASSWORD"
    add_nova_opt "quantum_admin_auth_url=$KEYSTONE_SERVICE_PROTOCOL://$KEYSTONE_SERVICE_HOST:$KEYSTONE_AUTH_PORT/v2.0"
    add_nova_opt "quantum_auth_strategy=$Q_AUTH_STRATEGY"
    add_nova_opt "quantum_admin_tenant_name=$SERVICE_TENANT_NAME"
    add_nova_opt "quantum_url=http://$Q_HOST:$Q_PORT"

    if [[ "$Q_PLUGIN" = "openvswitch" ]]; then
        NOVA_VIF_DRIVER="nova.virt.libvirt.vif.LibvirtHybridOVSBridgeDriver"
    elif [[ "$Q_PLUGIN" = "linuxbridge" ]]; then
        NOVA_VIF_DRIVER="nova.virt.libvirt.vif.QuantumLinuxBridgeVIFDriver"
    elif [[ "$Q_PLUGIN" = "ryu" ]]; then
        NOVA_VIF_DRIVER="nova.virt.libvirt.vif.LibvirtHybridOVSBridgeDriver"
        add_nova_opt "libvirt_ovs_integration_bridge=$OVS_BRIDGE"
    fi
    add_nova_opt "libvirt_vif_driver=$NOVA_VIF_DRIVER"
    add_nova_opt "linuxnet_interface_driver=$LINUXNET_VIF_DRIVER"
else
    add_nova_opt "network_manager=nova.network.manager.$NET_MAN"
    add_nova_opt "public_interface=$PUBLIC_INTERFACE"
    add_nova_opt "vlan_interface=$VLAN_INTERFACE"
    add_nova_opt "flat_network_bridge=$FLAT_NETWORK_BRIDGE"
    if [ -n "$FLAT_INTERFACE" ]; then
        add_nova_opt "flat_interface=$FLAT_INTERFACE"
    fi
fi
# All nova-compute workers need to know the vnc configuration options
# These settings don't hurt anything if n-xvnc and n-novnc are disabled
if is_service_enabled n-cpu; then
    NOVNCPROXY_URL=${NOVNCPROXY_URL:-"http://$SERVICE_HOST:6080/vnc_auto.html"}
    add_nova_opt "novncproxy_base_url=$NOVNCPROXY_URL"
    XVPVNCPROXY_URL=${XVPVNCPROXY_URL:-"http://$SERVICE_HOST:6081/console"}
    add_nova_opt "xvpvncproxy_base_url=$XVPVNCPROXY_URL"
fi
if [ "$VIRT_DRIVER" = 'xenserver' ]; then
    VNCSERVER_PROXYCLIENT_ADDRESS=${VNCSERVER_PROXYCLIENT_ADDRESS=169.254.0.1}
else
    VNCSERVER_PROXYCLIENT_ADDRESS=${VNCSERVER_PROXYCLIENT_ADDRESS=127.0.0.1}
fi
# Address on which instance vncservers will listen on compute hosts.
# For multi-host, this should be the management ip of the compute host.
VNCSERVER_LISTEN=${VNCSERVER_LISTEN=127.0.0.1}
add_nova_opt "vncserver_listen=$VNCSERVER_LISTEN"
add_nova_opt "vncserver_proxyclient_address=$VNCSERVER_PROXYCLIENT_ADDRESS"
add_nova_opt "ec2_dmz_host=$EC2_DMZ_HOST"
if is_service_enabled zeromq; then
    add_nova_opt "rpc_backend=nova.openstack.common.rpc.impl_zmq"
elif is_service_enabled qpid; then
    add_nova_opt "rpc_backend=nova.rpc.impl_qpid"
elif [ -n "$RABBIT_HOST" ] &&  [ -n "$RABBIT_PASSWORD" ]; then
    add_nova_opt "rabbit_host=$RABBIT_HOST"
    add_nova_opt "rabbit_password=$RABBIT_PASSWORD"
fi
add_nova_opt "glance_api_servers=$GLANCE_HOSTPORT"

# XenServer
# ---------

if [ "$VIRT_DRIVER" = 'xenserver' ]; then
    echo_summary "Using XenServer virtualization driver"
    read_password XENAPI_PASSWORD "ENTER A PASSWORD TO USE FOR XEN."
    add_nova_opt "compute_driver=xenapi.XenAPIDriver"
    XENAPI_CONNECTION_URL=${XENAPI_CONNECTION_URL:-"http://169.254.0.1"}
    XENAPI_USER=${XENAPI_USER:-"root"}
    add_nova_opt "xenapi_connection_url=$XENAPI_CONNECTION_URL"
    add_nova_opt "xenapi_connection_username=$XENAPI_USER"
    add_nova_opt "xenapi_connection_password=$XENAPI_PASSWORD"
    add_nova_opt "flat_injected=False"
    # Need to avoid crash due to new firewall support
    XEN_FIREWALL_DRIVER=${XEN_FIREWALL_DRIVER:-"nova.virt.firewall.IptablesFirewallDriver"}
    add_nova_opt "firewall_driver=$XEN_FIREWALL_DRIVER"
elif [ "$VIRT_DRIVER" = 'openvz' ]; then
    echo_summary "Using OpenVZ virtualization driver"
    # TODO(deva): OpenVZ driver does not yet work if compute_driver is set here.
    #             Replace connection_type when this is fixed.
    #             add_nova_opt "compute_driver=openvz.connection.OpenVzConnection"
    add_nova_opt "connection_type=openvz"
    LIBVIRT_FIREWALL_DRIVER=${LIBVIRT_FIREWALL_DRIVER:-"nova.virt.libvirt.firewall.IptablesFirewallDriver"}
    add_nova_opt "firewall_driver=$LIBVIRT_FIREWALL_DRIVER"
else
    echo_summary "Using libvirt virtualization driver"
    add_nova_opt "compute_driver=libvirt.LibvirtDriver"
    LIBVIRT_FIREWALL_DRIVER=${LIBVIRT_FIREWALL_DRIVER:-"nova.virt.libvirt.firewall.IptablesFirewallDriver"}
    add_nova_opt "firewall_driver=$LIBVIRT_FIREWALL_DRIVER"
fi


# Heat
# ----

if is_service_enabled heat; then
    echo_summary "Configuring Heat"
    init_heat
fi


# Launch Services
# ===============

# Only run the services specified in ``ENABLED_SERVICES``

# Launch the Glance services
if is_service_enabled g-api g-reg; then
    echo_summary "Starting Glance"
    start_glance
fi

# Create an access key and secret key for nova ec2 register image
if is_service_enabled key && is_service_enabled swift3 && is_service_enabled nova; then
    NOVA_USER_ID=$(keystone user-list | grep ' nova ' | get_field 1)
    NOVA_TENANT_ID=$(keystone tenant-list | grep " $SERVICE_TENANT_NAME " | get_field 1)
    CREDS=$(keystone ec2-credentials-create --user_id $NOVA_USER_ID --tenant_id $NOVA_TENANT_ID)
    ACCESS_KEY=$(echo "$CREDS" | awk '/ access / { print $4 }')
    SECRET_KEY=$(echo "$CREDS" | awk '/ secret / { print $4 }')
    add_nova_opt "s3_access_key=$ACCESS_KEY"
    add_nova_opt "s3_secret_key=$SECRET_KEY"
    add_nova_opt "s3_affix_tenant=True"
fi

screen_it zeromq "cd $NOVA_DIR && $NOVA_DIR/bin/nova-rpc-zmq-receiver"

# Launch the nova-api and wait for it to answer before continuing
if is_service_enabled n-api; then
    echo_summary "Starting Nova API"
    screen_it n-api "cd $NOVA_DIR && $NOVA_BIN_DIR/nova-api"
    echo "Waiting for nova-api to start..."
    if ! timeout $SERVICE_TIMEOUT sh -c "while ! http_proxy= wget -q -O- http://127.0.0.1:8774; do sleep 1; done"; then
      echo "nova-api did not start"
      exit 1
    fi
fi

if is_service_enabled q-svc; then
    echo_summary "Starting Quantum"
    # Start the Quantum service
    screen_it q-svc "cd $QUANTUM_DIR && python $QUANTUM_DIR/bin/quantum-server --config-file $Q_CONF_FILE --config-file /$Q_PLUGIN_CONF_FILE"
    echo "Waiting for Quantum to start..."
    if ! timeout $SERVICE_TIMEOUT sh -c "while ! http_proxy= wget -q -O- http://127.0.0.1:9696; do sleep 1; done"; then
      echo "Quantum did not start"
      exit 1
    fi

    # Configure Quantum elements
    # Configure internal network & subnet

    TENANT_ID=$(keystone tenant-list | grep " demo " | get_field 1)

    # Create a small network
    # Since quantum command is executed in admin context at this point,
    # ``--tenant_id`` needs to be specified.
    NET_ID=$(quantum net-create --tenant_id $TENANT_ID net1 | grep ' id ' | get_field 2)
    SUBNET_ID=$(quantum subnet-create --tenant_id $TENANT_ID --ip_version 4 --gateway $NETWORK_GATEWAY $NET_ID $FIXED_RANGE | grep ' id ' | get_field 2)
    if is_service_enabled q-l3; then
        # Create a router, and add the private subnet as one of its interfaces
        ROUTER_ID=$(quantum router-create --tenant_id $TENANT_ID router1 | grep ' id ' | get_field 2)
        quantum router-interface-add $ROUTER_ID $SUBNET_ID
        # Create an external network, and a subnet. Configure the external network as router gw
        EXT_NET_ID=$(quantum net-create ext_net -- --router:external=True | grep ' id ' | get_field 2)
        EXT_GW_IP=$(quantum subnet-create --ip_version 4 $EXT_NET_ID $FLOATING_RANGE -- --enable_dhcp=False | grep 'gateway_ip' | get_field 2)
        quantum router-gateway-set $ROUTER_ID $EXT_NET_ID
        if is_quantum_ovs_base_plugin "$Q_PLUGIN" && [[ "$Q_USE_NAMESPACE" = "True" ]]; then
            CIDR_LEN=${FLOATING_RANGE#*/}
            sudo ip addr add $EXT_GW_IP/$CIDR_LEN dev $PUBLIC_BRIDGE
            sudo ip link set $PUBLIC_BRIDGE up
            ROUTER_GW_IP=`quantum port-list -c fixed_ips -c device_owner | grep router_gateway | awk -F '"' '{ print $8; }'`
            sudo route add -net $FIXED_RANGE gw $ROUTER_GW_IP
        fi
        if [[ "$Q_USE_NAMESPACE" == "False" ]]; then
            # Explicitly set router id in l3 agent configuration
            iniset $Q_L3_CONF_FILE DEFAULT router_id $ROUTER_ID
        fi
   fi

elif is_service_enabled mysql && is_service_enabled nova; then
    # Create a small network
    $NOVA_BIN_DIR/nova-manage network create private $FIXED_RANGE 1 $FIXED_NETWORK_SIZE $NETWORK_CREATE_ARGS

    # Create some floating ips
    $NOVA_BIN_DIR/nova-manage floating create $FLOATING_RANGE

    # Create a second pool
    $NOVA_BIN_DIR/nova-manage floating create --ip_range=$TEST_FLOATING_RANGE --pool=$TEST_FLOATING_POOL
fi

# Start up the quantum agents if enabled
screen_it q-agt "python $AGENT_BINARY --config-file $Q_CONF_FILE --config-file /$Q_PLUGIN_CONF_FILE"
screen_it q-dhcp "python $AGENT_DHCP_BINARY --config-file $Q_CONF_FILE --config-file=$Q_DHCP_CONF_FILE"
screen_it q-l3 "python $AGENT_L3_BINARY --config-file $Q_CONF_FILE --config-file=$Q_L3_CONF_FILE"

if is_service_enabled nova; then
    echo_summary "Starting Nova"
    start_nova
fi
if is_service_enabled n-vol; then
    echo_summary "Starting Nova volumes"
    start_nvol
fi
if is_service_enabled cinder; then
    echo_summary "Starting Cinder"
    start_cinder
fi
if is_service_enabled ceilometer; then
    echo_summary "Configuring Ceilometer"
    configure_ceilometer
    echo_summary "Starting Ceilometer"
    start_ceilometer
fi
screen_it horizon "cd $HORIZON_DIR && sudo tail -f /var/log/$APACHE_NAME/horizon_error.log"
screen_it swift "cd $SWIFT_DIR && $SWIFT_DIR/bin/swift-proxy-server ${SWIFT_CONFIG_DIR}/proxy-server.conf -v"

# Starting the nova-objectstore only if swift3 service is not enabled.
# Swift will act as s3 objectstore.
is_service_enabled swift3 || \
    screen_it n-obj "cd $NOVA_DIR && $NOVA_BIN_DIR/nova-objectstore"

# launch heat engine, api and metadata
if is_service_enabled heat; then
    echo_summary "Starting Heat"
    start_heat
fi


# Install Images
# ==============

# Upload an image to glance.
#
# The default image is cirros, a small testing image which lets you login as **root**
# cirros also uses ``cloud-init``, supporting login via keypair and sending scripts as
# userdata.  See https://help.ubuntu.com/community/CloudInit for more on cloud-init
#
# Override ``IMAGE_URLS`` with a comma-separated list of UEC images.
#  * **oneiric**: http://uec-images.ubuntu.com/oneiric/current/oneiric-server-cloudimg-amd64.tar.gz
#  * **precise**: http://uec-images.ubuntu.com/precise/current/precise-server-cloudimg-amd64.tar.gz

if is_service_enabled g-reg; then
    echo_summary "Uploading images"
    TOKEN=$(keystone  token-get | grep ' id ' | get_field 2)

    # Option to upload legacy ami-tty, which works with xenserver
    if [[ -n "$UPLOAD_LEGACY_TTY" ]]; then
        IMAGE_URLS="${IMAGE_URLS:+${IMAGE_URLS},}http://images.ansolabs.com/tty.tgz"
    fi

    for image_url in ${IMAGE_URLS//,/ }; do
        upload_image $image_url $TOKEN
    done
fi


# Run local script
# ================

# Run ``local.sh`` if it exists to perform user-managed tasks
if [[ -x $TOP_DIR/local.sh ]]; then
    echo "Running user script $TOP_DIR/local.sh"
    $TOP_DIR/local.sh
fi


# Fin
# ===

set +o xtrace

if [[ -n "$LOGFILE" ]]; then
    exec 1>&3
    # Force all output to stdout and logs now
    exec 1> >( tee -a "${LOGFILE}" ) 2>&1
else
    # Force all output to stdout now
    exec 1>&3
fi


# Using the cloud
# ---------------

echo ""
echo ""
echo ""

# If you installed Horizon on this server you should be able
# to access the site using your browser.
if is_service_enabled horizon; then
    echo "Horizon is now available at http://$SERVICE_HOST/"
fi

# If Keystone is present you can point ``nova`` cli to this server
if is_service_enabled key; then
    echo "Keystone is serving at $KEYSTONE_AUTH_PROTOCOL://$SERVICE_HOST:$KEYSTONE_API_PORT/v2.0/"
    echo "Examples on using novaclient command line is in exercise.sh"
    echo "The default users are: admin and demo"
    echo "The password: $ADMIN_PASSWORD"
fi

# Echo ``HOST_IP`` - useful for ``build_uec.sh``, which uses dhcp to give the instance an address
echo "This is your host ip: $HOST_IP"

# Warn that ``EXTRA_FLAGS`` needs to be converted to ``EXTRA_OPTS``
if [[ -n "$EXTRA_FLAGS" ]]; then
    echo_summary "WARNING: EXTRA_FLAGS is defined and may need to be converted to EXTRA_OPTS"
fi

# Indicate how long this took to run (bash maintained variable ``SECONDS``)
echo_summary "stack.sh completed in $SECONDS seconds."
