=================
Project Creation
================

oc new-project ccairtime \
  --description="Project for testing apps" \
  --display-name="My Test Project"

=====================
Egress IP Assignment
=================

apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: egressip-ccairtime
spec:
  egressIPs:
  - 172.16.4.6
  namespaceSelector:
    matchLabels:
      name: ccairtime

=========================
Label your namespace
=========================

oc label namespaces ccairtime name=ccairtime 

=======================
To synch AD Group in Openshift
==============================

apiVersion: user.openshift.io/v1
kind: Group
metadata:
  annotations:
    openshift.io/ldap.uid: CN=ccairtime,OU=Global Security,OU=Groups,OU=Corp,DC=corp,DC=ae
    openshift.io/ldap.url: corp.du.ae:389
  labels:
    openshift.io/ldap.host: corp.ae
  name: ccairtime
users:

=======================
create rolebinding
==============================

oc adm policy add-role-to-group admin ccairtime
