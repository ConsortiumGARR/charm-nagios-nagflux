#!/bin/bash
set -ex

source charms.reactive.sh

@hook install
function install_nagios-nagflux() {
    # Do your setup here.
    #
    # If your charm has other dependencies before it can install,
    # add those as @when clauses above, or as additional @when
    # decorated handlers below.
    #
    # See the following for information about reactive charms:
    #
    #  * https://jujucharms.com/docs/devel/developer-getting-started
    #  * https://github.com/juju-solutions/layer-basic#overview
    #
    juju-log "Installing"
    status-set maintenance "Installing Nagflux"
    # apt packages are installed by the basic layer (see layer.yaml)

    # https://support.nagios.com/kb/article/nagios-core-performance-graphs-using-influxdb-nagflux-grafana-histou-802.html#Ubuntu
    export GOPATH=$JUJU_CHARM_DIR/gorepo
    mkdir -p $GOPATH
    go get -v -u github.com/griesbacher/nagflux
    go build github.com/griesbacher/nagflux 
    mkdir -p /opt/nagflux
    cp -f $GOPATH/bin/nagflux /opt/nagflux/
    mkdir -p /usr/local/nagios/var/spool/nagfluxperfdata
    chown nagios:nagios /usr/local/nagios/var/spool/nagfluxperfdata 

    # create and start the service
    cp -f $GOPATH/src/github.com/griesbacher/nagflux/nagflux.service /lib/systemd/system/
    chmod +x /lib/systemd/system/nagflux.service
    systemctl daemon-reload

    status-set blocked "Relation with influxdb missing"
    charms.reactive set_state 'nagios-nagflux.installed'
    set_flag nagflux_installed
}


@hook influxdb-api-relation-joined
function set_influxdb_api_changed_flag() {
    clear_flag influxdb_configured
}

@hook config-changed
function set_influxdb_configuration_changed_flag() {
    clear_flag influxdb_configured
}

@when_not influxdb_configured
@when nagflux_installed
@when_any influxdb-api.available config.set.external_influxdb_address
function configure-nagflux() {
    INFLUXDB_HOST_URL="$(config-get external_influxdb_address)"
    
    if [ -z "$INFLUXDB_HOST_URL" ]; then
        if ! relation-get hostname; then
            status-set blocked "InfluxDB not configured"
            return
        fi
        INFLUXDB_HOSTNAME=$(relation-get hostname)
        INFLUXDB_PORT=$(relation-get port)
        INFLUXDB_USERNAME=$(relation-get user)
        INFLUXDB_PASSWORD=$(relation-get password)
        #XXX username and password from an influxdb charm are not used
        INFLUXDB_HOST_URL="http://${INFLUXDB_HOSTNAME}:${INFLUXDB_PORT}"
    fi

    status-set maintenance "configuring nagflux"

    mkdir -p /var/lib/nagios3/spool/nagfluxperfdata
    chown nagios:nagios /var/lib/nagios3/spool/nagfluxperfdata

    LIVESTATUS_SOCKET=$( grep livestatus /etc/nagios3/nagios.cfg | awk '{print $2}' )
    if [ ! -S "$LIVESTATUS_SOCKET" ]; then
        status-set blocked "Nagios livestatus not enabled"
    fi

    cat <<EOF > /opt/nagflux/config.gcfg
[main]
    NagiosSpoolfileFolder = "/var/lib/nagios3/spool/nagfluxperfdata"
    NagiosSpoolfileWorker = 1
    InfluxWorker = 2
    MaxInfluxWorker = 5
    DumpFile = "nagflux.dump"
    NagfluxSpoolfileFolder = "/var/lib/nagios3/nagflux"
    FieldSeparator = "&"
    BufferSize = 10000
    FileBufferSize = 65536
    DefaultTarget = "all"

[Log]
    LogFile = ""
    MinSeverity = "INFO"

[Livestatus]
    # tcp or file
    Type = "tcp"
    # tcp: 127.0.0.1:6557 or file /var/run/live
    Address = "${LIVESTATUS_SOCKET}"
    # The amount to minutes to wait for livestatus to come up, if set to 0 the detection is disabled
    MinutesToWait = 2
    # Set the Version of Livestatus. Allowed are Nagios, Icinga2, Naemon.
    # If left empty Nagflux will try to detect it on it's own, which will not always work.
    Version = "Nagios"

[InfluxDBGlobal]
    CreateDatabaseIfNotExists = true
    NastyString = ""
    NastyStringToReplace = ""
    HostcheckAlias = "hostcheck"

[InfluxDB "nagflux"]
    Enabled = true
    Version = 1.0
    Address = "${INFLUXDB_HOST_URL}"
    Arguments = "precision=ms&db=nagflux"
    StopPullingDataIfDown = true

[InfluxDB "fast"]
    Enabled = false
    Version = 1.0
    Address = "${INFLUXDB_HOST_URL}"
    Arguments = "precision=ms&db=fast"
    StopPullingDataIfDown = false
EOF
    systemctl restart nagflux.service
    set_flag influxdb_configured

}

@when influxdb_configured
@when_not nagios_configured
function configure_nagios() {
    status-set maintenance "configuring nagios"
    sed -i 's/^process_performance_data=./process_performance_data=1/g' /etc/nagios3/nagios.cfg

    grep process-host-perfdata-file-nagflux /etc/nagios3/nagios.cfg || cat ${CHARM_DIR}/templates/10-nagflux-perfdata.cfg >> /etc/nagios3/nagios.cfg
    cp -f ${CHARM_DIR}/templates/20-nagflux-commands.cfg /etc/nagios3/conf.d/

    if /usr/sbin/nagios3 -v /etc/nagios3/nagios.cfg; then
        systemctl restart nagios3.service
        set_flag nagios_configured
        status-set active
    else
        status-set error "Nagios configuration error"
    fi
}

@hook influxdb-api-relation-departed
function clear_influxdb_configured_flag() {
    clear_flag influxdb_configured
    clear_flag nagios_configured
}

@hook start
function nagflux_start() {
    systemctl restart nagflux.service
    status-set active
}

@hook stop
function nagflux_stop() {
    clear_flag influxdb_configured
    clear_flag nagios_configured
    clear_flag nagflux_installed
    systemctl stop nagflux.service
    systemctl disable nagflux.service
    rm -rf /opt/nagflux
    rm -f /etc/nagios3/conf.d/20-nagflux-commands.cfg
    sed -i 's/^process_performance_data=./process_performance_data=0/g' /etc/nagios3/nagios.cfg
    systemctl restart nagios3.service
}

@hook update-status
function set_update_status_called_flag() {
    set_flag update_status_called
}

@when update_status_called influxdb_configured nagios_configured
function nagflux_update_status() {
    systemctl status nagflux.service || clear_flag influxdb_configured
    grep '^process_performance_data=0' /etc/nagios3/nagios.cfg && clear_flag nagios_configured
    clear_flag update_status_called
}

reactive_handler_main
