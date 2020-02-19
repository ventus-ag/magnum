#!/bin/bash

set +x
. /etc/sysconfig/heat-params
set -x
set -e

step="selinux disabling"
printf "Starting to run ${step}\n"

if [ "$(echo $COREOS_SELINUX_DISABLE | tr '[:upper:]' '[:lower:]')" == "true" ]; then

ssh_cmd="ssh -F /srv/magnum/.ssh/config root@localhost"

$ssh_cmd setenforce 0
$ssh_cmd sed -i 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config

fi

printf "Finished running ${step}\n"