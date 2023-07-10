#!/bin/bash

debug=

log() {
    echo "`date` SETUP: $@"
}

usage() {
    echo "Usage: setup.sh [--ydbd-tar <PATH_TO_YDBD_TAR> --config <PATH_TO_SETUP_CONFIG>]"
}

if ! command -v parallel-ssh &> /dev/null
then
    echo "'parallel-ssh' could not be found in your PATH. You can install it using the command: 'pip install parallel-ssh'."
    exit 1
fi

while [[ $# -gt 0 ]]; do case $1 in
    --ydbd)
        YDBD_TAR=$2
        shift;;
    --config)
        SETUP_CONFIG=$2
        shift;;
    --help|-h)
        usage
        exit;;
    *)
        usage
        exit;;
esac; shift; done

if [[ ! -e "$YDBD_TAR" ]]; then
    log "YDBD $YDBD_TAR is not exist"
    exit 1
fi

if [[ ! -e "$SETUP_CONFIG" ]]; then
  log "Config file $SETUP_CONFIG is not exist"
  exit 1
fi

source $SETUP_CONFIG

INIT_HOST=$(echo "$HOSTS" | tr ' ' '\n' | head -1)

echo "Kill ydbd"
$debug parallel-ssh -H "$HOSTS" -t 0 -p 20 "sudo sh -c 'pkill ydbd; sleep 5; pkill -9 ydbd; sudo rm -rf $YDB_SETUP_PATH/*'"

echo "mkdirs"
$debug parallel-ssh -H "$HOSTS" -t 0 -p 20 "sudo mkdir -p $YDB_SETUP_PATH/cfg $YDB_SETUP_PATH/logs"

echo "Upload ydbd"
$debug parallel-scp -H "$HOSTS" -t 0 -p 20 "$YDBD_TAR" "~"
$debug parallel-ssh -H "$HOSTS" -t 0 -p 20 "sudo tar -xzf ~/$(basename "$YDBD_TAR") --strip-component=1 -C $YDB_SETUP_PATH; \
                                            rm -f $(basename "$YDBD_TAR")"

echo "Format disks"
for d in "${DISKS[@]}"; do
  $debug parallel-ssh -H "$HOSTS" -t 0 -p 20 "sudo LD_LIBRARY_PATH=$YDB_SETUP_PATH/lib $YDB_SETUP_PATH/bin/ydbd admin bs disk obliterate $d"
done

echo "Upload config"
$debug parallel-scp -H "$HOSTS" -t 0 -p 20 $CONFIG_DIR/config.yaml "~"
$debug parallel-ssh -H "$HOSTS" -t 0 -p 20 "sudo mv ~/config.yaml $YDB_SETUP_PATH/cfg"
$debug parallel-scp -H "$HOSTS" -t 0 -p 20 $CONFIG_DIR/config_dynnodes.yaml "~"
$debug parallel-ssh -H "$HOSTS" -t 0 -p 20 "sudo mv ~/config_dynnodes.yaml $YDB_SETUP_PATH/cfg"

GRPC_PORT=$GRPC_PORT_BEGIN
IC_PORT=$IC_PORT_BEGIN
MON_PORT=$MON_PORT_BEGIN

NODE_BROKERS=$(echo "$HOSTS" | tr ' ' '\n' | sed "s/.*/--node-broker &:$GRPC_PORT/" | tr '\n' ' ')

echo "Start static nodes"
$debug parallel-ssh -H "$HOSTS" -t 0 -p 20 "sudo LD_LIBRARY_PATH=$YDB_SETUP_PATH/lib bash -c 'nohup \
    $YDB_SETUP_PATH/bin/ydbd server --log-level 3 --tcp --yaml-config $YDB_SETUP_PATH/cfg/config.yaml \
    --grpc-port $((GRPC_PORT++)) --ic-port $((IC_PORT++)) --mon-port $((MON_PORT++)) --node static &>$YDB_SETUP_PATH/logs/static.log &'"
$debug sleep 10s

echo "Init BS"
$debug parallel-ssh -H "$INIT_HOST" -t 0 -p 20  \
    "sudo LD_LIBRARY_PATH=$YDB_SETUP_PATH/lib $YDB_SETUP_PATH/bin/ydbd admin blobstorage config init --yaml-file $YDB_SETUP_PATH/cfg/config.yaml"

$debug parallel-ssh -H "$INIT_HOST" -t 0 -p 20  \
    "sudo LD_LIBRARY_PATH=$YDB_SETUP_PATH/lib $YDB_SETUP_PATH/bin/ydbd admin database $DATABASE_NAME create $STORAGE_POOLS"

if [[ $DYNNODE_COUNT -gt ${#DYNNODE_TASKSET_CPU[@]} ]]; then
  echo "DYNNODE_COUNT is greater than DYNNODE_TASKSET_CPU. The values are equalized."
  DYNNODE_COUNT=${#DYNNODE_TASKSET_CPU[@]}
fi

for ind in $(seq 0 $(($DYNNODE_COUNT-1))); do
  echo "Start dynnodes: $(($ind+1))"
  $debug parallel-ssh -H "$HOSTS" -t 0 -p 20 "sudo bash -c ' \
      taskset -c ${DYNNODE_TASKSET_CPU[$ind]} nohup \
      sudo LD_LIBRARY_PATH=$YDB_SETUP_PATH/lib $YDB_SETUP_PATH/bin/ydbd server --log-level 3 --grpc-port $((GRPC_PORT++)) --ic-port $((IC_PORT++)) --mon-port $((MON_PORT++)) \
      --yaml-config  $YDB_SETUP_PATH/cfg/config_dynnodes.yaml \
      --tenant $DATABASE_NAME \
      $NODE_BROKERS \
      &>$YDB_SETUP_PATH/logs/dyn$(($ind+1)).log &'"
done
