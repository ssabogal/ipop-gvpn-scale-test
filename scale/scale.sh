#!/bin/sh

cd $(dirname "$0")
cwd=$(pwd)

CONF_FILE="./scale.cfg"             # path to the configuration file (relative to this script)
NODE_PATH="./node"                  # path to the node directory (relative to this script)
FORWARDER_PROGRAM='visualizer.py'   # path to the visualizer program (relative to this script)

NODE_NODE_SCRIPT='./node/node.bash' # path to the node script (relative to the nodes' initial pwd)

TEMP_DIR=".tmp.sources/"
TEMP_ARCHIVE=".node.tar.gz"

index()
{
    echo $1 | cut -d " " -f $2
}

# parse config file
. $CONF_FILE
NR_NODES=$(echo "$NODES" | wc -w)

# main
while :; do

    # prompt for command
    echo -n "> "
    read line
    cmd=$(index "$line" 1)
    args="${line#* }"

    # process command
    case $cmd in
        ("download")
            IPOP_CONTROLLER_REPO="https://github.com/ipop-project/controllers"
            IPOP_TINCAN_URL="https://github.com/ipop-project/Downloads/releases/download/$TINCAN/ipop-${TINCAN}_ubuntu.tar.gz"

            mkdir $TEMP_DIR; cd $TEMP_DIR

            # obtain controller sources
            git clone $IPOP_CONTROLLER_REPO
            cd controllers
            git checkout $CONTROLLER
            cd $cwd/$TEMP_DIR
            cp -r controllers/controller $cwd/node/ipop/

            # obtain ipop-tincan binary
            wget $IPOP_TINCAN_URL
            tar xf ipop-${TINCAN}_ubuntu.tar.gz
            cp ipop-${TINCAN}_ubuntu/ipop-tincan $cwd/node/ipop/

            cd $cwd; rm -rf $TEMP_DIR
            ;;
        ("accept")
            echo "enter 'yes' to add a node to the list of known hosts"
            for node in $NODES; do
                ssh $node "echo 'accepted connection: $node'"
            done
            ;;
        ("install")
            # compress local sources; transfer sources to each node; nodes install
            tar -zcvf $TEMP_ARCHIVE $NODE_PATH
            for node in $NODES; do
                sh -c "
                    scp $TEMP_ARCHIVE $node:~/
                    ssh $node 'tar xf $TEMP_ARCHIVE; bash $NODE_NODE_SCRIPT install';
                " &
            done
            wait
            rm $TEMP_ARCHIVE
            ;;
        ("init")
            # initialize containers (vnodes)
            for i in $(seq 1 $NR_NODES); do
                min=$((($i-1) * ($SIZE / $NR_NODES)))
                max=$((($i * ($SIZE / $NR_NODES)) - 1))

                node=$(index "$NODES" $i)
                ssh $node "bash $NODE_NODE_SCRIPT init-containers $min $max" &
            done
            wait

            # initialize ejabberd
            ssh $SERVER "bash $NODE_NODE_SCRIPT init-server $SIZE"
            ;;
        ("restart")
            ssh $SERVER "bash $NODE_NODE_SCRIPT restart-server"
            ;;
        ("clear")
            # remove containers
            for node in $NODES; do
                 ssh $node "bash $NODE_NODE_SCRIPT exit-containers" &
            done
            wait

            # remove ejabberd
            ssh $SERVER "bash $NODE_NODE_SCRIPT exit-server"
            ;;
        ("source")
            # compress local sources; transfer sources to each node; nodes update souces of each vnode
            tar -zcvf $TEMP_ARCHIVE $NODE_PATH
            for node in $NODES; do
                sh -c "
                    scp $TEMP_ARCHIVE $node:~/
                    ssh $node 'tar xf $TEMP_ARCHIVE; bash $NODE_NODE_SCRIPT source';
                " &
            done
            wait
            rm $TEMP_ARCHIVE
            ;;
        ("config")
            vpn_type=$(index "$args" 1)
            serv_addr=$(echo "$SERVER" | cut -d "@" -f2)
            fwdr_addr=$(echo "$FORWARDER" | cut -d "@" -f2)
            fwdr_port='50101'
            params="${args#* }"

            # vnodes create IPOP config files
            for node in $NODES; do
                ssh $node "bash $NODE_NODE_SCRIPT config $vpn_type $serv_addr $fwdr_addr $fwdr_port $params" &
            done
            wait
            ;;
        ("forward")
            forwarder_addr=$(echo "$FORWARDER" | cut -d "@" -f2)
            forwarder_port='50101'
            forwarded_port=$(index "$args" 1)

            # launch forwarder
            ssh $FORWARDER "bash $NODE_NODE_SCRIPT forward $forwarder_addr $forwarder_port $forwarded_port &" &
            echo "connect visualizer to $forwarder_addr $forwarded_port"
            ;;
        ("visualize")
            forwarder_addr=$(echo "$FORWARDER" | cut -d "@" -f2)
            forwarded_port=$(index "$args" 1)
            vpn_type=$(index "$args" 2)

            python3 $FORWARDER_PROGRAM tcp $forwarder_addr $forwarded_port $vpn_type &
            ;;
        ("run" | "kill")
            # check if 'all' is present
            if [ $(index "$args" 1) = "all" ]; then
                args="$(seq 0 $(($SIZE-1)))"
            fi

            # create list of vnodes for each node
            for i in $(seq 1 $NR_NODES); do
                node_list=""

                for j in $args; do
                    n=$(($j / ($SIZE / $NR_NODES) + 1))
                    if [ "$n" = "$i" ]; then
                        node_list="$node_list $j"
                    fi
                done

                node=$(index "$NODES" $i)

                # nodes run list of vnodes
                if [ "$cmd" = "run" ]; then
                    ssh $node "bash $NODE_NODE_SCRIPT run '${node_list}' &" &
                elif [ "$cmd" = "kill" ]; then
                    ssh $node "bash $NODE_NODE_SCRIPT kill '${node_list}' &" &
                fi
            done
            ;;
        ("quit" | "exit")
            exit 0
            ;;
        (*)
            echo 'usage:'
            echo '  platform management:'
            echo '    download                       : download controller sources and ipop-tincan binary'
            echo '    accept                         : manually enable connections'
            echo '    install                        : install/prepare resources'
            echo '    init      [size]               : initialize platform'
            echo '    restart                        : restart services'
            echo '    clear                          : clear platform'
            echo '    source                         : upload sources'
            echo '    config    <args>               : create IPOP config file'
            echo '    forward   <gvpn|svpn> <port>   : run forwarder in background'
            echo '    visualize <port> <gvpn|svpn>   : run forwarder in background'
            echo ''
            echo '  IPOP network simulation:'
            echo '    run       [list|all]           : run list|all nodes'
            echo '    kill      [list|all]           : kill list|all nodes'
            echo ''
            echo '  utility:'
            echo '    quit|exit                      : quit program'
            ;;
    esac
done
