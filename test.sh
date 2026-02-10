#!/bin/bash

STREAM_REPLICAS=3 # R3
MAX_DELIVER=2 # 2 delivery attempts + 30s -> dead-lettered
MESSAGES=200 # around ~150 msgs, dead-lettered msgs started to vanish
NATS_SERVER_READY_TIMEOUT_SECONDS=10
CONSUMER_GRACE_PERIOD="60s" # > default ack timeout (30s)
MONITORING_STREAM_NAME="monitoring"
DLQ_CONSUMER_NAME="dlq-monitor"
WQ_STREAM_NAME="wq"
WQ_CONSUMER_NAME="c-wq-0"

CONSUMER_DIR="./consumer"
CONSUMER_EXE="consumer"
CONSUMER="$CONSUMER_DIR/$CONSUMER_EXE"

TEMP_DIR="./tmp"
DLQ_LOG_FILE="$TEMP_DIR/dlq-monitor.log"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
RED='\033[0;31m'
NC='\033[0m' # No Color

if [ ! -f "$CONSUMER" ]; then
    echo -e "${GREEN}=== Building Consumer Executable ===${NC}"
    (cd "$CONSUMER_DIR" && go build -ldflags="-s -w" -gcflags="all=-l -B" -o "$CONSUMER_EXE" .)
    echo -e "${GREEN}Done${NC}"
fi

sudo rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

echo -e "\n${GREEN}=== Installing NATS Server ===${NC}"
sudo docker compose up -d

echo -e "\n${CYAN}Waiting for NATS server to be ready (timeout: ${NATS_SERVER_READY_TIMEOUT_SECONDS}s)..${NC}"
curl "http://localhost:8222/healthz" --connect-timeout 1 -m 1 --retry "$NATS_SERVER_READY_TIMEOUT_SECONDS" --retry-delay 1 -s > /dev/null

if [ $? -ne 0 ]; then
    echo -e "${RED}NATS server is not ready after ${NATS_SERVER_READY_TIMEOUT_SECONDS}s${NC}"
    exit 1
fi
echo -e "${GREEN}NATS server is ready${NC}"

echo -e "\n${GREEN}=== Configuring NATS Server ===${NC}\n"

echo -e "${CYAN}Creating stream '$MONITORING_STREAM_NAME'${NC}"
nats stream add --subjects='$JS.EVENT.ADVISORY.>' --defaults --storage=memory --replicas="$STREAM_REPLICAS" --retention=limits --discard=new "$MONITORING_STREAM_NAME"

echo -e "\n${CYAN}Creating consumer '$DLQ_CONSUMER_NAME'${NC}"
nats consumer add --filter='$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.>' --defaults --ack=explicit --deliver=all --pull --replay=instant "$MONITORING_STREAM_NAME" "$DLQ_CONSUMER_NAME"

echo -e "\n${CYAN}Creating stream '$WQ_STREAM_NAME'${NC}"
nats stream add --subjects="wq.*" --defaults --storage=memory --replicas="$STREAM_REPLICAS" --retention=work --discard=new "$WQ_STREAM_NAME"

echo -e "\n${CYAN}Creating consumer '$WQ_CONSUMER_NAME'${NC}"
nats consumer add --filter="wq.0" --defaults --ack=explicit --deliver=all --pull --replay=instant --max-deliver="$MAX_DELIVER" "$WQ_STREAM_NAME" "$WQ_CONSUMER_NAME"

echo -e "\n${GREEN}=== Running Workloads ===${NC}\n"

nats pub wq.0 --count "$MESSAGES" '{{ID}}' -H Nats-Msg-Id:{{ID}} -q -J --sleep=500ms &
PRODUCER_PID=$!

"$CONSUMER" -stream "$WQ_STREAM_NAME" -consumer "$WQ_CONSUMER_NAME" -msgs "$MESSAGES" -max-deliver "$MAX_DELIVER" -grace-period "$CONSUMER_GRACE_PERIOD" &
CONSUMER_PID=$!

echo -e "\n${MAGENTA}Producers and consumer started${NC}"
echo -e "\n${CYAN}Waiting for producer to finish...${NC}"

wait $PRODUCER_PID
echo -e "\n${GREEN} -- Producer has finished --${NC}\n"

wait $CONSUMER_PID
echo -e "\n${GREEN} -- Consumer has finished --${NC}\n"

echo -e "\n${GREEN}=== Analyzing API Monitor Logs ===${NC}\n"

echo -e "${CYAN}Fetching msgs from monitoring consumers${NC}"
nats consumer next --count=5000 --timeout=5s "$MONITORING_STREAM_NAME" "$DLQ_CONSUMER_NAME" > "$DLQ_LOG_FILE" 2>&1 || true

DLQ_ENTRIES=$(grep -E '^\{' "$DLQ_LOG_FILE" 2>/dev/null)
if [ -n "$DLQ_ENTRIES" ]; then
    DLQ_COUNT=$(echo "$DLQ_ENTRIES" | wc -l)
else
    DLQ_COUNT=0
fi
echo "$DLQ_COUNT dead-lettered messages"

nats s report
nats s subjects "$MONITORING_STREAM_NAME"

echo -e "\n${CYAN}Checking dead-lettered messages${NC}"
DNF_COUNT=0

if [ -n "$DLQ_ENTRIES" ] && [ "$DLQ_COUNT" -gt 0 ]; then
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        
        STREAM=$(echo "$entry" | jq -r '.stream')
        STREAM_SEQ=$(echo "$entry" | jq -r '.stream_seq')
        
        echo -n "  Checking seq $STREAM_SEQ on stream $STREAM.."
        
        RESULT=$(nats s get -j "$STREAM" "$STREAM_SEQ" 2>&1)
        if [ $? -ne 0 ] || echo "$RESULT" | grep -q "no message found"; then
            echo -e " ${RED}NOT FOUND${NC}"
            ((DNF_COUNT++))
        else
            echo -e " ${GREEN}OK${NC}"
        fi
    done <<< "$DLQ_ENTRIES"
fi

if [ "$DNF_COUNT" -eq 0 ]; then
    echo -e "\n${GREEN}All dead-lettered messages were found in their respective streams.${NC}"
else
    echo -e "\n${RED}DNFs: $DNF_COUNT out of $DLQ_COUNT dead-lettered messages missing${NC}"
fi

echo -e "\n${GREEN}=== Uninstalling NATS Server ===${NC}\n"

sudo docker compose down
