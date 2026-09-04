#!/bin/bash

# sysinfo_page - A script to produce an system information HTML file

##### Constants

TITLE="ATP Unix Checklist System Information for $HOSTNAME"
RIGHT_NOW="$(date +"%x %r %Z")"
TIME_STAMP="Updated on $RIGHT_NOW by $USER"


prs()
{
desc="Power Redundancy on Server"
    echo "<tr><td rowspan="10">Physical Readiness</td><td>$desc</td><td>Not Applicable</td><td></td><td></td><td>VMware Machine</td></tr>"
}
prr()
{
desc="Power Redundancy on RACK"
    echo "<tr><td>$desc</td><td>Not Applicable</td><td></td><td></td><td>VMware Machine</td></tr>"
}
nr()
{
desc="Network Redundancy"
    echo "<tr><td>$desc</td><td>Not Applicable</td><td></td><td></td><td>VMware Machine</td></tr>"
}
sl()
{
desc="Server Labelling"
    echo "<tr><td>$desc</td><td>Not Applicable</td><td></td><td></td><td>VMware Machine</td></tr>"
}
label()
{
desc="Power/Network/Fibre Labelling"
    echo "<tr><td>$desc</td><td>Not Applicable</td><td></td><td></td><td>VMware Machine</td></tr>"
}
ssr()
{
desc="Servicebiliy (Sufficient Space to replace HW)"
    echo "<tr><td>$desc</td><td>Not Applicable</td><td></td><td></td><td>VMware Machine</td></tr>"
}
sc()
{
desc="Structered Cabling"
    echo "<tr><td>$desc</td><td>Not Applicable</td><td></td><td></td><td>VMware Machine</td></tr>"
}
hbar()
{
desc="HBA Redundancy"
    echo "<tr><td>$desc</td><td>Not Applicable</td><td></td><td></td><td>VMware Machine</td></tr>"
}
led()
{
desc="LED / Panel Status (Any Amber / Error Messages)"
    echo "<tr><td>$desc</td><td>Not Applicable</td><td></td><td></td><td>VMware Machine</td></tr>"
}
rca()
{
desc="Remote Console Access"
    echo "<tr><td>$desc</td><td>Not Applicable</td><td></td><td></td><td>VMware Machine</td></tr>"
}
dm()
{
desc="Internal Disks Mirror and boot from both mirror disk"
    echo "<tr><td rowspan="3">Availability</td><td>$desc</td><td>Not Applicable</td><td></td><td></td><td>VMware Machine</td></tr>"
}
ntts()
{
desc="Network Teaming  and test status"
    echo "<tr><td>$desc</td><td>Not Applicable</td><td></td><td></td><td>VMware Machine</td></tr>"
}
ors()
{
desc="OS Recovery Solution "
    echo "<tr><td>$desc</td><td>Compliant</td><td>Backup Snapshot restore</td><td></td><td></td></tr>"
}



var="CPU Average   :"
cpu=`sar | tail -1 | awk '{print $8}'`
var1=`echo "((100 - $cpu))"| bc -l`
var2="Load Average   :"
var3=`uptime | awk -F'load average:' '{ print $2 }' | cut -f1 -d,`
var4="Health Status  :"
var5=`uptime | awk -F'load average:' '{ print $2 }' | cut -f1 -d, | awk '{if ($1 > 5) print "Not Complaint"; else if ($1 > 3) print "Caution"; else print "Compliant"}'`

cpu()
{
desc="Current CPU Threshold level (<80%)"
    echo "<tr><td>$desc</td><td>$var5</td><td></td><td></td><td></td></tr>"
}

TOTALMEM=`free -g | head -2 | tail -1| awk '{print $2}'`
TOTALBC=`echo "scale=2;if($TOTALMEM<1024 && $TOTALMEM > 0) print 0;$TOTALMEM/1024"| bc -l`
USEDMEM=`free -g | head -2 | tail -1| awk '{print $3}'`
USEDBC=`echo "scale=2;if($USEDMEM<1024 && $USEDMEM > 0) print 0;$USEDMEM/1024"|bc -l`
FREEMEM=`free -m | head -2 | tail -1| awk '{print $4}'`
FREEBC=`echo "(($TOTALMEM - $USEDMEM))"|bc -l`
varmem=`echo $FREEBC| cut -f1 -d .`
permem=`echo "scale=0;(($USEDMEM * 100 / $TOTALMEM))"|bc -l`
mem_status()
{
desc="Current Memory threshold level(<80%)"
if [ $permem -ge 80 ]; then
    mem="Not Compliant"
    echo "<tr><td>$desc</td><td>$mem</td><td></td><td></td><td></td></tr>"
else
    mem="Compliant"
    echo "<tr><td>$desc</td><td>$mem</td><td></td><td></td><td></td></tr>"
fi
}

disk_status()
{
desc="Current Filesystem threshold level(<80%)"
if df -Ph | sed s/%//g | grep -v Filesystem| awk '{if($5 >= 80) print "Unhealthy";else print "OK";}' | grep Unhealthy &>  /dev/null; [ $? -eq 0 ]; then
   disk="Not Compliant"
   echo "<tr><td rowspan="4">Monitoring</td><td>$desc</td><td>$disk</td><td></td><td></td><td></td></tr>"
else
   disk="Compliant"
   echo "<tr><td rowspan="4">Monitoring</td><td>$desc</td><td>$disk</td><td></td><td></td><td></td></tr>"
fi
}

upt()
{
up=$(uptime | awk '{print $3}' | cut -f 1 -d :)
p="System UP time (<180 days)"
if [ $up -le 180 ]; then
    pas="Compliant"
    echo "<tr><td>$p</td><td><font color=green>$pas</font></td><td></td><td></td><td></td></tr>"
else
    pas="Not Compliant"
    echo "<tr><td>$p</td><td><font color=red>$pas</font></td><td>$st</td><td></td><td></td></tr>"
fi
}

sendmail_status()
{
desc="SMTP Configured"
if grep -q "DSsmtpint" /etc/mail/sendmail.cf && systemctl is-active --quiet "sendmail"; then
    sendmail="Compliant"
    echo "<tr><td>$desc</td><td><font color=green>$sendmail</font></td><td></td><td></td><td></td></tr>"
elif grep -q "smtpint" /etc/postfix/main.cf && systemctl is-active --quiet "postfix"; then
    sendmail="Compliant"
    echo "<tr><td>$desc</td><td><font color=green>$sendmail</font></td><td></td><td></td><td>Postfix installed and running</td></tr>"
else
    sendmail="Not Compliant"
    echo "<tr><td>$desc</td><td><font color=red>$sendmail</font></td><td></td><td></td><td></td></tr>"
fi
}

ilo()
{
desc="Remote Console(ILO/MP) Accessbility and password to be shared for ILO and chassis information "
    echo "<tr><td rowspan="3">Accessibilty</td><td>$desc</td><td>Not Applicable</td><td></td><td></td><td>VMware Machine</td></tr>"
}

vdi()
{
desc="System Accessibility from ducorp/vpn/ssl/citrix and VDI ( Masdar and IMPZ)"
    echo "<tr><td>$desc</td><td>Compliant</td><td></td><td></td><td>VM is accessible through VDI</td></tr>"
}

lic()
{
desc="Availability of OS Support from Vender"
    echo "<tr><td rowspan="5">Support and License</td><td>$desc</td><td>Compliant</td><td></td><td></td><td>VMware support license</td></tr>"
}

hws()
{
desc="Availability of HW Support "
    echo "<tr><td>$desc</td><td>Not Applicable</td><td></td><td></td><td>VMware support license</td></tr>"
}

ilolic()
{
desc="ILO Licensed"
    echo "<tr><td>$desc</td><td>Not Applicable</td><td></td><td></td><td>VMware support license</td></tr>"
}

ossub()
{
desc="OS and Cluster Subscriptions to be provided "
    echo "<tr><td>$desc</td><td>Pending</td><td></td><td></td><td>Standard Support License</td></tr>"
}

soflic()
{
desc="Licenses for Installed softwares"
    echo "<tr><td>$desc</td><td>Pending</td><td></td><td></td><td>Project Managemnet to provide</td></tr>"
}

prc()
{
desc="Power Redundancy check"
    echo "<tr><td rowspan="23">ATP</td><td>$desc</td><td>Not Applicable</td><td></td><td></td><td>VMware Machine</td></tr>"
}

ssr()
{
desc="Server Normal Shutdown and application redundancy test"
    echo "<tr><td>$desc</td><td>Complaint</td><td></td><td></td><td></td></tr>"
}

sns()
{
desc="Server Normal Startup"
    echo "<tr><td>$desc</td><td>Compliant</td><td></td><td></td><td></td></tr>"
}

hrc()
{
desc="HBA Redundancy Check"
    echo "<tr><td>$desc</td><td>Not Applicable</td><td></td><td></td><td>VMware Machine</td></tr>"
}

nrc()
{
desc="Network Redundancy Check"
    echo "<tr><td>$desc</td><td>Not Applicable</td><td></td><td></td><td>VMware Machine</td></tr>"
}

abc()
{
desc="Alternate Boot check"
    echo "<tr><td>$desc</td><td>Complaint</td><td>Restore from Snapshot Backup</td><td></td><td>VMware Machine</td></tr>"
}

acj()
{
desc="Application team to confirm no root filesystem is used for application day to day activity no root dependacy for application team to view /read/rotate application logs or configration files and no application cron jobs under root user"
    echo "<tr><td>$desc</td><td>Pending</td><td>Application team to confirm</td><td></td><td></td></tr>"
}

vmh()
{
desc="Vmware team alignmnet for Vmware server handover"
    echo "<tr><td>$desc</td><td>Pending</td><td></td><td></td><td>VMware team to confirm</td></tr>"
}

rpr()
{
usr1=$(grep "(ALL)" /etc/sudoers | egrep -v "#|root|sysadm|dmidecode|qualyadm|wheel" | awk '{print $1}')
su="root password restriction (Only sys admins are allowed to use root)"
re="Root Access can be revoked post handover"
if grep "(ALL)" /etc/sudoers | egrep -v "#|root|sysadm|dmidecode|qualyadm|wheel|gsitdatabaseadministration" > /dev/null; [ $? -eq 0 ]; then
    sud="Not Compliant"
    echo "<tr><td>$su</td><td><font color=red>$sud</font></td><td>$usr1 have root access</td><td></td><td>$re</td></tr>"
else
    sud="Compliant"
    echo "<tr><td>$su</td><td><font color=green>$sud</font></td><td>$usr1</td><td></td><td></td></tr>"
fi
}

cfg2html_status()
{
c="Explorer or cfg2html configuration on OS"
if crontab -l | grep -w cfg2html-linux > /dev/null && ls /usr/sbin/ | grep cfg2html-linux > /dev/null;  [ $? -eq 0 ]; then
    cfg2html="Compliant"
    echo "<tr><td>$c</td><td><font color=green>$cfg2html</font></td><td></td><td></td><td></td></tr>"
else
    cfg2html="Not Compliant"
    echo "<tr><td>$c</td><td><font color=red>$cfg2html</font></td><td></td><td></td><td></td></tr>"
fi
}


edr_status()
{
e="HIDS/Fidelis and Trellix has been depreciated confirmation by TSRM"
mdt="Fidelis and Trellix has been depreciated." 
mdf="Fidelis is depreciated."
#if systemctl list-unit-files | grep -q '^endpoint.service'; [ $? -ne 0 ] && systemctl is-active --quiet xagt; then
if systemctl list-unit-files | egrep -q '^endpoint.servicei|xagt'; [ $? -ne 0 ];  then
    edr="Compliant"
    echo "<tr><td>$e</td><td><font color=green>$edr</font></td><td></td><td></td><td>$mdt</td></tr>"
else
    edr="Not Compliant"
    echo "<tr><td>$e</td><td><font color=red>$edr</font></td><td></td><td></td><td>$mdf</td></tr>"
fi
}

av_status()
{
av="Anti Virus"
mdt="Symantec is depreciated. Microsoft Defender has beein installed"
mdf="Symantec is depreciated. Please install the Microsoft Defender"
#if /usr/lib/symantec/status.sh > /dev/null;  [ $? -eq 0 ]; then
#if mdatp health > /dev/null;  [ $? -eq 0 ] && /usr/lib/symantec/status.sh > /dev/null;  [ $? -ne 0 ]; then
if /usr/lib/symantec/status.sh > /dev/null;  [ $? -ne 0 ] && systemctl is-active --quiet mdatp; then
    sym="Compliant"
    echo "<tr><td>$av</td><td><font color=green>$sym</font></td><td></td><td></td><td>$mdt</td></tr>"
else
    sym="Not Compliant"
    echo "<tr><td>$av</td><td><font color=red>$sym</font></td><td></td><td></td><td>$mdf</td></tr>"
fi
}

ad_status()
{
ad="AD integration validate by adding own ID and login"
if realm list | grep corp.du.ae > /dev/null;  [ $? -eq 0 ]; then
    rea="Compliant"
    echo "<tr><td>$ad</td><td><font color=green>$rea</font></td><td></td><td></td><td></td></tr>"
else
    rea="Not Compliant"
    echo "<tr><td>$ad</td><td><font color=red>$rea</font></td><td></td><td></td><td></td></tr>"
fi
}

chrony_status()
{
srv=`grep server /etc/chrony.conf | grep -v "#"`
ch="Synchronization with NTP/Chrony Server and ensure 4 NTP servers should be configured on upcoming project"
if grep  -q server /etc/chrony.conf && systemctl is-active --quiet "chronyd"; then
    chr="Compliant"
    echo "<tr><td rowspan="3">Configuration</td><td>$ch</td><td><font color=green>$chr</font></td><td>$srv</td><td></td></tr>"
else
    chr="Not Compliant"
    st="Service is not running or NTP Server not configured"
    echo "<tr><td rowspan="3">Configuration</td><td>$ch</td><td><font color=red>$chr</font></td><td>$srv</td><td>$st</td></tr>"
fi
}

hpom_status()
{
srv="Please secure approval from Shadi and contact ITFaultPerformanceMgmt@du.ae team to install agent"
ov="HPOM Monitoring agents"
if ps -ef | grep OV | grep -v grep > /dev/null; then
    hpm="Compliant"
    echo "<tr><td>$ov</td><td><font color=green>$hpm</font></td><td></td><td></td><td></td></tr>"
else
    hpm="Not Compliant"
    echo "<tr><td>$ov</td><td><font color=red>$hpm</font></td><td>$srv</td><td></td><td></td></tr>"
fi
}



pass_status()
{
st=$(grep -E "PASS_MAX_DAYS|PASS_MIN_DAYS|PASS_MIN_LEN|PASS_WARN_AGE" /etc/login.defs |grep -v "#")
MAX=$(grep -E "PASS_MAX_DAYS" /etc/login.defs |grep -v "#" | awk '{print $2}')
MIN=$(grep -E "PASS_MIN_DAYS" /etc/login.defs |grep -v "#" | awk '{print $2}')
LEN=$(grep -E "PASS_MIN_LEN" /etc/login.defs |grep -v "#" | awk '{print $2}')
WARN=$(grep -E "PASS_WARN_AGE" /etc/login.defs |grep -v "#" | awk '{print $2}')
p="Password Policy compliance"
if [ $MAX -eq 60 ] && [ $MIN -eq 1 ] && [ $LEN -eq 16 ] && [ $WARN -eq 10 ]; then
    pas="Compliant"
    echo "<tr><td>$p</td><td><font color=green>$pas</font></td><td></td><td></td><td></td></tr>"
elif [ $MAX -eq 60 ] && [ $MIN -eq 1 ] && [ $WARN -eq 10 ]; then
    pas="Compliant"
    echo "<tr><td>$p</td><td><font color=green>$pas</font></td><td></td><td></td><td></td></tr>"
else
    pas="Not Compliant"
    echo "<tr><td>$p</td><td><font color=red>$pas</font></td><td>$st</td><td></td><td></td></tr>"
fi
}

sud_status()
{
usr=$(cat /etc/passwd |  grep -Ev "nologin|sbin|root|sysadm" | cut -f1 -d :)
su="No user in sudoers/rbac with root privilege"
usr1=$(cat /etc/sudoers | grep -v "#" | grep -w "(ALL)" | egrep "$usr" | awk '{print $1}')
if cat /etc/sudoers | grep -v "#" | grep -w "(ALL) ALL" | egrep "$usr" > /dev/null; [ $? -eq 0 ]; then
    sud="Not Compliant"
    echo "<tr><td>$su</td><td><font color=red>$sud</font></td><td>$usr1 have sudo rights</td><td></td><td></td></tr>"
else
    sud="Compliant"
    echo "<tr><td>$su</td><td><font color=green>$sud</font></td><td>$usr1</td><td></td><td></td></tr>"
fi
}

flar()
{
desc="Flar Image backup"
    echo "<tr><td>$desc</td><td>Compliant</td><td></td><td></td><td>Not Applicable on VM</td></tr>"
}

dcr()
{
desc="Validate the server with DCR sheet for compute resourcec ,IP ,subnet"
    echo "<tr><td>$desc</td><td>Pending</td><td>DCR provided</td><td></td><td>Unix Ops team to validate</td></tr>"
}

ova()
{
desc="OVPA perfoamnce graph should report the perfomance"
    echo "<tr><td>$desc</td><td>Pending</td><td>Project team to request ITFaultPerformanceMgmt@du to provide OVA performance reports</td><td></td><td>Unix Ops team to validate</td></tr>"
}

sar_status()
{
sa="Sar  utility to be installed and configured"
if sar > /dev/null; [ $? -eq 0 ]; then
    sar="Compliant"
    echo "<tr><td>$sa</td><td><font color=green>$sar</font></td><td></td><td></td><td></td></tr>"
else
    sar="Not Compliant"
    echo "<tr><td>$sa</td><td><font color=red>$sar</font></td><td></td><td></td><td></td></tr>"
fi
}

ans_status()
{
desc="Ansible communication should be enabled"
    echo "<tr><td>$desc</td><td>Pending</td><td></td><td></td><td>Unix Ops to confirm</td></tr>"
}

cra_status()
{
cr="Crash dump configured with enough  Space  and to be configured as sperate file system if memory >= 32GB"
fr=`free -g | head -2 | tail -1| awk '{print $2}'`
if [ $fr -lt 32 ]; then
   cra="Compliant"
   echo "<tr><td>$cr</td><td><font color=green>$cra</font></td><td>Crash mountpoint not needed, Total Memory is less than 32 GB</td><td></td></tr>"
elif [ $fr -gt 32 ] && df -h | grep crash > /dev/null; [ $? -eq 0 ]; then
   cra="Compliant"
   echo "<tr><td>$cr</td><td><font color=green>$cra</font></td><td></td><td></td><td></td></tr>"
else
    cra="Not Complaint"
    echo "<tr><td>$cr</td><td><font color=red>$cra</font></td><td></td><td></td><td></td></tr>"
fi
}

sat_status()
{
rs="Ensure satellite communication should be enabled"

timeout 2s curl  -v "telnet://meylvrhsa01.corp.du.ae:443" > /tmp/curl1.txt 2>&1;
if cat /tmp/curl1.txt | grep "Connected" > /dev/null; then
    rst="Compliant"
    echo "<tr><td>$rs</td><td><font color=green>$rst</font></td><td></td><td></td><td></td></tr>"
else
    rst="Not Complaint"
    echo "<tr><td>$rs</td><td><font color=red>$rst</font></td><td></td><td></td><td></td></tr>"
fi
}

sys_status()
{
sy="Syslog integration and confirmation by TSRM"
sy1=$(systemctl is-active rsyslog)
if systemctl is-active --quiet rsyslog && [ -s /var/log/messages ]; then
    sys="Compliant"
    echo "<tr><td>$sy</td><td><font color=green>$sys</font></td><td></td><td></td><td></td></tr>"
else
    sys="Not Compliant"
    echo "<tr><td>$sy</td><td><font color=red>$sys</font></td><td>$sy1</td><td></td><td></td></tr>"
fi
}

gim_status()
{
gm="Please secure ISRM approval for Guardium Installation"
gi="Guardium Agnet installation and conifrmaiton by TSRM"
if grep -q oracle /etc/passwd && ps -ef | grep gim | grep -v grep > /dev/null; then
    gim="Compliant"
    echo "<tr><td>$gi</td><td><font color=green>$gim</font></td><td></td><td></td><td></td></tr>"
elif ps -ef | grep pmon | grep -v grep > /dev/null; [ $? -eq 1 ];  then
    gim="Compliant"
    echo "<tr><td>$gi</td><td><font color=green>$gim</font></td><td></td><td></td><td>No Database available</td></tr>"
else
    gim="Not Compliant"
    echo "<tr><td>$gi</td><td><font color=red>$gim</font></td><td>$gm</td><td></td><td></td></tr>"
fi
}

if pcs status > /dev/null; [ $? -eq 0 ]; then
   pcs=cls0
fi
echo $pcs

case $pcs in
cls0)

clh()
{
desc="Cluster Healthcheck.All Vendor specific parameters to be configured.Time out tobe configured,failover test ,vmotion test etc"
    echo "<tr><td rowspan="8">Cluster</td><td>$desc</td><td>Pending</td><td></td><td></td><td>Unix Ops to Validate</td></tr>"
}

cls_status()
{
cl="Cluster health check"
#st=$(pcs cluster status | grep Online | tail -2 | wc -l)
st=$(pcs cluster status | grep Online)
sta=$(pcs cluster status | grep Online | tail -2)
if pcs cluster status | grep Online > /dev/null; [ $? -eq 0 ]; then
    cls="Compliant"
    echo "<tr><td>$cl</td><td><font color=green>$cls</font></td><td>$sta</td><td></td><td></td></tr>"
else
    cls="Not Compliant"
    echo "<tr><td>$cl</td><td><font color=red>$cls</font></td><td>$sta</td><td></td><td></td></tr>"
fi
}

tot_status()
{
to="heartbeat/totem token value"
tot=$(corosync-cmapctl | grep totem.token  | grep -v .totem.token)
if corosync-cmapctl | grep totem.token | grep -v .totem.token > /dev/null; [ $? -eq 0 ]; then
    tok="Compliant"
    echo "<tr><td>$to</td><td><font color=green>$tok</font></td><td>$tot</td><td></td><td></td></tr>"
else
    tok="Not Compliant"
    echo "<tr><td>$to</td><td><font color=red>$tok</font></td><td>$tot</td><td></td><td></td></tr>"
fi
}

sto_status()
{
so1="Validate fencing device configuration"
so3="Stonith Levels to be added (kdump First - Fence - Second)"
sto1=$(pcs stonith status | grep Started | awk '{print $3,$4,$5}')
sto11=$(pcs stonith status)
sto3=$(pcs stonith level config | egrep  "kdump|vmfence")
so4="Access of fencing device vmfence"
sohost=$(hostname -s)
sto4=$(fence_vmware_soap -a MEYLVVCS03.corp.du.ae -l "DUCORP\hcm.vcenter" -p 'Hcmcloud12#$67' --ssl-insecure --ssl -z -o status -n `hostname`)
sto42=$(fence_vmware_soap -a MASLVVCS03.corp.du.ae -l "DUCORP\hcm.vcenter" -p 'Hcmcloud12#$67' --ssl-insecure --ssl -z -o status -n `hostname`)
sto41="ERROR: Server side certificate verification failed<br>ERROR: Unable to connect/login to fencing device"
if pcs stonith status | grep Started > /dev/null; [ $? -eq 0 ]; then
    sto="Compliant"
    echo "<tr><td>$so1</td><td><font color=green>$sto</font></td><td>$sto1</td><td></td><td></td></tr>"
else
    sto="Not Compliant"
    echo "<tr><td>$so1</td><td><font color=red>$sto</font></td><td>$sto11</td><td></td><td></td></tr>"
fi
if pcs stonith level config | egrep  "kdump|vmfence" > /dev/null; [ $? -eq 0 ]; then
    sto="Compliant"
    echo "<tr><td>$so3</td><td><font color=green>$sto</font></td><td>$sto3</td><td></td><td></td></tr>"
else
    sto="Not Compliant"
    echo "<tr><td>$so3</td><td><font color=red>$sto</font></td><td>$sto3</td><td></td><td></td></tr>"
fi
if [[ "$sohost" == mey* ]]; then
    echo "Server is in Production" 
    if fence_vmware_soap -a MEYLVVCS03.corp.du.ae -l "DUCORP\hcm.vcenter" -p 'Hcmcloud12#$67' --ssl-insecure --ssl -z -o status -n `hostname` > /dev/null; [ $? -eq 0 ]; then
    sto="Compliant"
    echo "<tr><td>$so4</td><td><font color=green>$sto</font></td><td>$sto4</td><td></td><td></td></tr>"
    else 
    sto="Not Compliant"
    echo "<tr><td>$so4</td><td><font color=red>$sto</font></td><td>$sto4</td><td></td><td></td></tr>"
    fi
elif [[ "$sohost" == mas* ]]; then
    echo "Server is in DR" 
    if fence_vmware_soap -a MASLVVCS03.corp.du.ae -l "DUCORP\hcm.vcenter" -p 'Hcmcloud12#$67' --ssl-insecure --ssl -z -o status -n `hostname` > /dev/null; [ $? -eq 0 ]; then
    sto="Compliant"
    echo "<tr><td>$so4</td><td><font color=green>$sto</font></td><td>$sto42</td><td></td><td></td></tr>"
    else
    sto="Not Compliant"
    echo "<tr><td>$so4</td><td><font color=red>$sto</font></td><td>$sto42</td><td></td><td></td></tr>"
    fi 
else
    sto="Not Compliant"
    echo "<tr><td>$so4</td><td><font color=red>$sto</font></td><td>$sto4<br>$sto42</td><td></td><td></td></tr>"
fi
}

lvm_pcs()
{
lv="lvm confiruration for pcs cluster (Applicable id FS exist)"
lvm=$(pcs status | grep LVM | grep  -v Started)
if pcs status | grep LVM | grep  -v Started > /dev/null; [ $? -eq 1 ]; then
    lvc="Compliant"
    echo "<tr><td>$lv</td><td><font color=green>$lvc</font></td><td></td><td></td><td></td></tr>"
else
    lvc="Not Compliant"
    echo "<tr><td>$lv</td><td><font color=red>$lvc</font></td><td></td><td></td><td></td></tr>"
fi
}

kf_status()
{
kf="Kdump and Fence resources should not be part of any resource group"
kfr=$(pcs resource | grep -E "vmfence|kdump")
if pcs resource | grep -E "vmfence|kdump" > /dev/null; [ $? -eq 1 ]; then
    kfc="Compliant"
    echo "<tr><td>$kf</td><td><font color=green>$kfc</font></td><td></td><td></td><td></td></tr>"
else
    kfc="Not Compliant"
    echo "<tr><td>$kf</td><td><font color=red>$kfc</font></td><td></td><td>$kfr</td><td></td></tr>"
fi
}

;;
*)


clh()
{
desc="Cluster Healthcheck.All Vendor specific parameters to be configured.Time out tobe configured,failover test ,vmotion test etc"
    echo "<tr><td rowspan="6">Cluster</td><td>$desc</td><td>Not Applicable</td><td></td><td></td><td>No Cluster</td></tr>"
}

cls_status()
{
cl="Cluster health check"
sta=$(pcs cluster status | grep Online | tail -2)
    echo "<tr><td>$cl</td><td>Not Applicable</td><td>$sta</td><td></td><td>No PCS Cluster</td></tr>"
}

tot_status()
{
to="heartbeat/totem token value"
tot=$(corosync-cmapctl | grep totem.token  | grep -v .totem.token)
    echo "<tr><td>$to</td><td>Not Applicable</td><td>$tot</td><td></td><td>No PCS Cluster</td></tr>"
}

sto_status()
{
so1="Validate fencing device configuration"
so3="Stonith Levels to be added (kdump First - Fence - Second)"
sto1=$(pcs stonith status | grep Started | awk '{print $3,$4,$5}')
sto11=$(pcs stonith status)
sto3=$(pcs stonith level config | egrep  "kdump|vmfence")
so4="Access of fencing device vmfence"
sto4=$(fence_vmware_soap -a 10.175.69.6 -l "DUCORP\hcm.vcenter" -p 'Hcmcloud12#$67' --ssl-insecure --ssl -z -o status -n `hostname`)
sto41="ERROR: Server side certificate verification failed<br>ERROR: Unable to connect/login to fencing device"
    echo "<tr><td>$so1</td><td>Not Applicable</td><td>$sto1</td><td></td><td>No PCS Cluster</td></tr>"
    echo "<tr><td>$so3</td><td>Not Applicable</td><td>$sto3</td><td></td><td>No PCS Cluster</td></tr>"
    echo "<tr><td>$so4</td><td>Not Applicable</td><td></td><td></td><td>No PCS Cluster</td></tr>"
}

;;
esac

if ps -ef | grep pmon | grep -v grep > /dev/null; [ $? -eq 0 ]; then
    ora=ora0
        echo "Oracle Database Configured"
fi
echo $ora

case $ora in
ora0)


lo_status()
{
lo="loopback interface MTU"
mt=$(cat /sys/class/net/lo/mtu)
if [[ $mt -lt 18000 ]]; then
    mtu="Compliant"
    echo "<tr><td rowspan="3">Oracle</td><td>$lo</td><td><font color=green>$mtu</font></td><td>$mt</td></tr>"
else
    mtu="Not Compliant"
    echo "<tr><td rowspan="3">Oracle</td><td>$lo</td><td><font color=red>$mtu</font></td><td>$mt</td></tr>"
fi
}

mfr_status()
{
mf="vm.min_free_kbytes 0.5% * total_memory"
fk=$(grep vm.min_free_kbytes /etc/sysctl.conf)
if grep -q vm.min_free_kbytes /etc/sysctl.conf; then
    mfr="Compliant"
    echo "<tr><td>$mf</td><td><font color=green>$mfr</font></td><td>$fk</td></tr>"
else
    mfr="Not Compliant"
    echo "<tr><td>$mf</td><td><font color=red>$mfr</font></td><td>No Parameter set</td></tr>"
fi
}

hps_status()
{
hp="HugePages Settings vm.nr_hugepages"
hs=$(grep vm.nr_hugepages /etc/sysctl.conf)
if grep -q vm.nr_hugepages /etc/sysctl.conf; then
    hps="Compliant"
    echo "<tr><td>$hp</td><td><font color=green>$hps</font></td><td>$hs</td></tr>"
else
    hps="Not Compliant"
    echo "<tr><td>$hp</td><td><font color=red>$hps</font></td><td>No Parameter set</td></tr>"
fi
}
;;
*)

echo "No Oracle"

;;
esac


##### Main

cat > checklist_`hostname`.html <<- _EOF_
  <html>
  <head>
      <title>$TITLE</title>
  </head>

  <body>
      <h1>$TITLE</h1>
      <p>$TIME_STAMP</p>
<table border="1"><tr><th align= "left">Hostname: </th><td colspan="5" align= "center">`hostname`</td></tr><tr><th align= "left">IP Address :</th><td colspan="5" align= "center">`hostname -I`</td></tr><tr><th align= "left">OS version :</th><td colspan="5" align= "center">`cat /etc/redhat-release`</td></tr><tr><th align= "left">Kernel Version: </th><td colspan="5" align= "center">`uname -r`</td></tr><tr><th align= "left">Uptime           : </th><td colspan="5" align= "center">`uptime | sed 's/.*up \([^,]*\), .*/\1/'`</td></tr><tr><th align= "left">Last Reboot Time : </th><td colspan="5" align= "center">`who -b | awk '{print $3,$4}'`</td></tr></tr>
     <style>
      table, th, td {
        border:1px solid black;
        border-collapse: collapse;
      }
      </style>
      <tr><th width="10%">Category</th><th width="35%">Snag Description Item</th><th width="8%">Compliance</th><th width="20%">Resolution</th><th>Status</th><th>Remark</th></tr>
      $(prs)
          $(prr)
      $(nr)
      $(sl)
      $(label)
      $(ssr)
      $(sc)
      $(hbar)
      $(led)
      $(rca)
      $(dm)
      $(ntts)
      $(ors)
      $(disk_status)
      $(cpu)
      $(mem_status)
          $(upt)
      $(chrony_status)
      $(sendmail_status)
      $(cra_status)
          $(ilo)
          $(vdi)
          $(sud_status)
      $(lic)
      $(hws)
      $(ilolic)
      $(ossub)
      $(soflic)
          $(clh)
          $(cls_status)
      $(tot_status)
      $(sto_status)
      $(lvm_pcs)
      $(kf_status)
      $(prc)
      $(ssr)
      $(sns)
      $(hrc)
      $(nrc)
      $(abc)
          $(pass_status)
      $(acj)
          $(vmh)
          $(rpr)
      $(cfg2html_status)
      $(ad_status)
      $(av_status)
      $(edr_status)
          $(hpom_status)
      $(gim_status)
      $(sys_status)
          $(flar)
          $(dcr)
          $(ova)
      $(sar_status)
      $(sat_status)
      $(ans_status)
      $(lo_status)
      $(mfr_status)
      $(hps_status)
          </table>
<div class="footer">
<p>.................................................................................................................................................Implementation Unix Checklist</p>
</div>
  </body>
  </html>
_EOF_
