#!/usr/bin/env bash

mkdir -p /etc/frr
mkdir -p /etc/supervisor/conf.d

CFGGEN_PARAMS=" \
    -d \
    -y /etc/sonic/constants.yml \
    -t /usr/share/sonic/templates/frr_vars.j2 \
    -t /usr/share/sonic/templates/bgpd/bgpd.conf.j2,/etc/frr/bgpd.conf \
    -t /usr/share/sonic/templates/zebra/zebra.conf.j2,/etc/frr/zebra.conf \
    -t /usr/share/sonic/templates/staticd/staticd.conf.j2,/etc/frr/staticd.conf \
    -t /usr/share/sonic/templates/frr.conf.j2,/etc/frr/frr.conf \
    -t /usr/share/sonic/templates/isolate.j2,/usr/sbin/bgp-isolate \
    -t /usr/share/sonic/templates/unisolate.j2,/usr/sbin/bgp-unisolate \
"
CONFIG_TYPE=$(sonic-cfggen $CFGGEN_PARAMS)

update_default_gw()
{
   IP_VER=${1}
   # FRR is not running in host namespace so we need to delete
   # default gw kernel route added by docker network via eth0 and add it back
   # with higher administrative distance so that default route learnt
   # by FRR becomes best route if/when available
   GATEWAY_IP=$(ip -${IP_VER} route show default dev eth0 | awk '{print $3}')
   #Check if docker default route is there
   if [[ ! -z "$GATEWAY_IP" ]]; then
      ip -${IP_VER} route del default dev eth0
      #Make sure route is deleted
      CHECK_GATEWAY_IP=$(ip -${IP_VER} route show default dev eth0 | awk '{print $3}')
      if [[ -z "$CHECK_GATEWAY_IP" ]]; then
         # Ref: http://docs.frrouting.org/en/latest/zebra.html#zebra-vrf
         # Zebra does treat Kernel routes as special case for the purposes of Admin Distance. \
         # Upon learning about a route that is not originated by FRR we read the metric value as a uint32_t.
         # The top byte of the value is interpreted as the Administrative Distance and
         # the low three bytes are read in as the metric.
         # so here we are programming administrative distance of 210 (210 << 24) > 200 (for routes learnt via IBGP)
         ip -${IP_VER} route add default via $GATEWAY_IP dev eth0 metric 3523215360
      fi
      if [[ "$IP_VER" == "4" ]]; then
          # Add route in default table. This is needed for BGPMON to route BGP Ipv4 loopback
          # traffic from namespace to host
          ip -${IP_VER} route add table default default via $GATEWAY_IP dev eth0 metric 3523215360
      fi
   fi
}

if [[ ! -z "$NAMESPACE_ID" ]]; then
   update_default_gw 4
   update_default_gw 6
fi

if [ -z "$CONFIG_TYPE" ] || [ "$CONFIG_TYPE" == "separated" ]; then
    echo "no service integrated-vtysh-config" > /etc/frr/vtysh.conf
    rm -f /etc/frr/frr.conf
elif [ "$CONFIG_TYPE" == "unified" ]; then
    echo "service integrated-vtysh-config" > /etc/frr/vtysh.conf
    rm -f /etc/frr/bgpd.conf /etc/frr/zebra.conf /etc/frr/staticd.conf
fi

chown -R frr:frr /etc/frr/

chown root:root /usr/sbin/bgp-isolate
chmod 0755 /usr/sbin/bgp-isolate

chown root:root /usr/sbin/bgp-unisolate
chmod 0755 /usr/sbin/bgp-unisolate

mkdir -p /var/sonic
echo "# Config files managed by sonic-config-engine" > /var/sonic/config_status

rm -f /var/run/rsyslogd.pid

supervisorctl start rsyslogd

# start eoiu pulling, only if configured so
if [[ $(sonic-cfggen -d -v 'WARM_RESTART.bgp.bgp_eoiu if WARM_RESTART and WARM_RESTART.bgp and WARM_RESTART.bgp.bgp_eoiu') == 'true' ]]; then
    supervisorctl start bgp_eoiu_marker
fi

# Start Quagga processes
supervisorctl start zebra
supervisorctl start staticd

addr="127.0.0.1"
port=2601
start=$(date +%s.%N)
timeout 5s bash -c -- "until </dev/tcp/${addr}/${port}; do sleep 0.1;done"
if [ "$?" != "0" ]; then
    logger -p error "Error: zebra is not ready to accept connections"
else
    timespan=$(awk "BEGIN {print $(date +%s.%N)-$start; exit}")
    logger -p info "It took ${timespan} seconds to wait for zebra to be ready to accept connections"
fi

supervisorctl start bgpd

if [ "$CONFIG_TYPE" == "unified" ]; then
    supervisorctl start vtysh_b
fi

supervisorctl start fpmsyncd

supervisorctl start bgpcfgd
supervisorctl start bgpmon