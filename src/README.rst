Overview
--------

Nagflux is a connector which stores the performance data from Nagios into InfluxDB

This subordinate charm installs and configures nagflux on a Nagios host. References:

- https://support.nagios.com/kb/article/nagios-core-performance-graphs-using-influxdb-nagflux-grafana-histou-802.html#Ubuntu
- https://github.com/Griesbacher/nagflux


Usage
-----

To use it, deploy it and add relations to nagios and influxdb::

    juju deploy nagios
    juju config nagios enable_livestatus=true
    juju deploy influxdb
    juju deploy cs:~csd-garr/nagios-nagflux
    juju add-relation nagios-nagflux:juju-info nagios:juju-info
    juju add-relation influxdb nagios-nagflux:influxdb-api

Please note that livestatus should be enabled in the ``nagios`` charm.


Contact Information
-------------------

Distributed Compunting and Storage group at GARR, the Italian research and education network:

- https://cloud.garr.it
- https://www.garr.it/it/


