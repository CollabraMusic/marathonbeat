#!/bin/bash

usage()
{
    echo "Usage: $(basename $0) -t logz_io_token"
    echo "Options:"
    echo "  -t    token to use with logz.io"
}

error()
{
    echo "$1" >&2
    exit 3
}

log()
{
    echo "$1"
}

DOCKER_GEN_DIRECTORY=/usr/bin
DOCKER_GEN_PATH=${DOCKER_GEN_DIRECTORY}/docker-gen
install_docker_gen()
{
    local DOCKER_GEN_TAR_PATH=/tmp/docker-gen.tar

    wget https://github.com/jwilder/docker-gen/releases/download/0.7.3/docker-gen-linux-amd64-0.7.3.tar.gz -O ${DOCKER_GEN_TAR_PATH} -nv
    tar xvzf ${DOCKER_GEN_TAR_PATH} -C ${DOCKER_GEN_DIRECTORY}
    chmod +x ${DOCKER_GEN_PATH}
}

install_filebeat()
{
    local FILEBEAT_DEB_PATH=/tmp/filebeat.deb
    wget https://download.elastic.co/beats/filebeat/filebeat_1.2.3_amd64.deb -O ${FILEBEAT_DEB_PATH}  -nv
    sudo dpkg -i ${FILEBEAT_DEB_PATH}
}

if [ "${UID}" -ne 0 ];
then
    error "You must be root to run this script."
fi

TOKEN=""

while getopts ":t:" optname; do
  log "Option $optname set"
  case ${optname} in
    t) TOKEN=${OPTARG};;
    h) help; exit 1;;
   \?) help; error "Option -${OPTARG} not supported.";;
    :) help; error "Option -${OPTARG} requires an argument.";;
  esac
done

if [ ! ${TOKEN} ];
then
    usage
    error "Token is required."
fi

# Install Filebeat, if it doesn't exist already
which filebeat &>/dev/null
FILEBEAT_EXISTS=$?
if [[ ${FILEBEAT_EXISTS} != 0 ]]; then
    install_filebeat
fi

# Install docker-gen, this will generate the filebeat.yml
which docker-gen &>/dev/null
DOCKER_GEN_EXISTS=$?
if [[ ${DOCKER_GEN_EXISTS} != 0 ]]; then
    install_docker_gen
fi

# Install the logz.io certificate if it doesn't exist
CERTIFICATE_PATH=/etc/ssl/certs/COMODORSADomainValidationSecureServerCA.crt
if [ ! -f ${CERTIFICATE_PATH} ]; then
    wget https://raw.githubusercontent.com/cloudflare/cfssl_trust/master/intermediate_ca/COMODORSADomainValidationSecureServerCA.crt -O ${CERTIFICATE_PATH} -nv
    chmod 777 ${CERTIFICATE_PATH}
fi

MARATHONBEAT_CONFIG_DIRECTORY=/etc/marathonbeat/
FILEBEAT_TEMPLATE_PATH=${MARATHONBEAT_CONFIG_DIRECTORY}filebeat.tmpl
mkdir -p ${MARATHONBEAT_CONFIG_DIRECTORY}
echo '
############################# Filebeat #####################################
{{ $token := "'${TOKEN}'" }}
filebeat:
  prospectors:
{{ range $key, $value := . }}
    # {{ $value.Env.MARATHON_APP_ID }}
{{ $base_path := (first ( where $value.Mounts "Destination" "/mnt/mesos/sandbox" )).Source }}
    -
      paths:
        - {{ $base_path  }}/stdout
      fields:
        app_id: {{ $value.Env.MARATHON_APP_ID }}
        level: info
        logzio_codec: plain
        token: {{ $token }}
      fields_under_root: true
    -
      paths:
        - {{ $base_path }}/stderr
      fields:
        app_id: {{ $value.Env.MARATHON_APP_ID }}
        level: error
        logzio_codec: plain
        token: {{ $token }}
      fields_under_root: true
{{ end }}
  registry_file: /var/lib/filebeat/registry
############################# Output ##########################################
output:
  logstash:
    hosts: ["listener.logz.io:5015"]
    tls:
      certificate_authorities: ["'${CERTIFICATE_PATH}'"]
' > ${FILEBEAT_TEMPLATE_PATH}

FILEBEAT_CONFIG_PATH=/etc/filebeat/filebeat.yml


MARATHONBEAT_SERVICE_PATH=/lib/systemd/system/marathonbeat.service
echo '
[Unit]
Description=A file generator that renders the filebeat.yml using Docker Container meta-data.
Documentation=https://github.com/jwilder/docker-gen
After=network.target docker.socket
Requires=docker.socket

[Service]
ExecStart='${DOCKER_GEN_PATH} '-watch  -notify "systemctl restart filebeat"' ${FILEBEAT_TEMPLATE_PATH} ${FILEBEAT_CONFIG_PATH} '

[Install]
WantedBy=multi-user.target
' > ${MARATHONBEAT_SERVICE_PATH}
chmod 664 ${MARATHONBEAT_SERVICE_PATH}
systemctl daemon-reload
systemctl restart marathonbeat
systemctl enable marathonbeat
