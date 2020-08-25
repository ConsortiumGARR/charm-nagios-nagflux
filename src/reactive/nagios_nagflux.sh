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
}

@hook influxdb-api-relation-changed
function configure-nagflux() {
    status-set maintenance "configuring"
    INFLUXDB_HOSTNAME=$(relation-get hostname)
    INFLUXDB_PORT=$(relation-get port)
    INFLUXDB_USERNAME=$(relation-get user)
    INFLUXDB_PASSWORD=$(relation-get password)

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
    Address = "http://${INFLUXDB_HOSTNAME}:${INFLUXDB_PORT}"
    Arguments = "precision=ms&u=${INFLUXDB_USERNAME}&p=${INFLUXDB_PASSWORD}&db=nagflux"
    StopPullingDataIfDown = true

[InfluxDB "fast"]
    Enabled = false
    Version = 1.0
    Address = "http://${INFLUXDB_HOSTNAME}:${INFLUXDB_PORT}"
    Arguments = "precision=ms&u=${INFLUXDB_USERNAME}&p=${INFLUXDB_PASSWORD}&db=fast"
    StopPullingDataIfDown = false
EOF

    sed -i 's/^process_performance_data=./process_performance_data=1/g' /etc/nagios3/nagios.cfg

    grep process-host-perfdata-file-nagflux /etc/nagios3/nagios.cfg || cat ${CHARM_DIR}/templates/10-nagflux-perfdata.cfg >> /etc/nagios3/nagios.cfg
    cp -f ${CHARM_DIR}/templates/20-nagflux-commands.cfg /etc/nagios3/conf.d/

    systemctl restart nagflux.service

    if /usr/sbin/nagios3 -v /etc/nagios3/nagios.cfg; then
        systemctl restart nagios3.service
        status-set active
    else
        status-set error "Nagios configuration error"
    fi
}

@hook start
function nagflux_start() {
    systemctl restart nagflux.service
        status-set active
}

@hook stop
function nagflux_stop() {
    systemctl stop nagflux.service
    systemctl disable nagflux.service
    rm -rf /opt/nagflux
    rm -f /etc/nagios3/conf.d/20-nagflux-commands.cfg
    sed -i 's/^process_performance_data=./process_performance_data=0/g' /etc/nagios3/nagios.cfg
    systemctl restart nagios3.service
}

reactive_handler_main
