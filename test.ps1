$streamReplicas = 3 # R3
$maxDeliver = 2 # 2 delivery attempts + 30s -> dead-lettered
$messages = 200 # around ~150 msgs, dead-lettered msgs started to vanish
$natsServerReadyTimeoutSeconds = 10
$consumerGracePeriod = "60s" # > default ack timeout (30s)
$monitoringStreamName = "monitoring"
$dlqConsumerName = "dlq-monitor"
$wqStreamName = "wq"
$wqConsumerName = "c-wq-0"

$consumerDir = ".\consumer"
$consumerExe = "consumer.exe"
$consumer = "$consumerDir\$consumerExe"
$tempDir = ".\tmp\"
$dlqLogFile = "$tempDir\dlq-monitor.log"

if ((Test-Path $consumer) -eq $false) {
    Write-Host "`n=== Building Consumer Executable ===" -ForegroundColor Green
    & go build -C $consumerDir -ldflags="-s -w" -gcflags=all="-l -B" -o $consumerExe .
    Write-Host "Done" -ForegroundColor Green
}

Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path $tempDir -ItemType Directory | Out-Null

Write-Host "`n=== Installing NATS Server ===" -ForegroundColor Green
& docker-compose up -d

Write-Host "`nWaiting for NATS server to be ready (timeout: $($natsServerReadyTimeoutSeconds)s).." -ForegroundColor Cyan
curl.exe "http://localhost:8222/healthz" --connect-timeout 1 -m 1 --retry $natsServerReadyTimeoutSeconds --retry-delay 1 -s | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Host "NATS server is not ready after $($natsServerReadyTimeoutSeconds)s" -ForegroundColor Red
    return
}
Write-Host "NATS server is ready" -ForegroundColor Green

Write-Host "`n=== Configuring NATS Server ===" -ForegroundColor Green
Write-Host "Creating stream '$monitoringStreamName'" -ForegroundColor Cyan
& nats stream add --subjects='$JS.EVENT.ADVISORY.>' --defaults --storage=memory --replicas=$streamReplicas --retention=limits --discard=new $monitoringStreamName

Write-Host "`nCreating consumer '$dlqConsumerName'" -ForegroundColor Cyan
& nats consumer add --filter='$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.>' --defaults --ack=explicit --deliver=all --pull --replay=instant $monitoringStreamName $dlqConsumerName

Write-Host "`nCreating stream '$wqStreamName'" -ForegroundColor Cyan
& nats stream add --subjects="wq.*" --defaults --storage=memory --replicas=$streamReplicas --retention=work --discard=new $wqStreamName

Write-Host "`nCreating consumer '$wqConsumerName'" -ForegroundColor Cyan
& nats consumer add --filter="wq.0" --defaults --ack=explicit --deliver=all --pull --replay=instant --max-deliver=$maxDeliver $wqStreamName $wqConsumerName

Write-Host "Done" -ForegroundColor Green

Write-Host "`n=== Running Workloads ===`n" -ForegroundColor Green
$pproc = Start-Process -FilePath nats.exe -ArgumentList "pub wq.0 --count $messages '{{ID}}' -H Nats-Msg-Id:{{ID}} -q -J --sleep=500ms" -NoNewWindow -PassThru # remove the --sleep param so see the DLQ working as expected
$cproc = Start-Process -FilePath $Consumer -ArgumentList "-stream $wqStreamName -consumer $wqConsumerName -msgs $messages -max-deliver $maxDeliver -grace-period $consumerGracePeriod" -NoNewWindow -PassThru

Write-Host "Producers and consumer started" -ForegroundColor Magenta
Write-Host "`nWaiting for producer to finish..." -ForegroundColor Cyan
$pproc.WaitForExit()
Write-Host "`n -- Producer has finished --`n" -ForegroundColor Green

$cproc.WaitForExit()
Write-Host "`n -- Consumer has finished --`n" -ForegroundColor Green

Write-Host "`n=== Analyzing API Monitor Logs ===`n" -ForegroundColor Green
nats consumer next --count=$($messages*2) $monitoringStreamName $dlqConsumerName > $dlqLogFile 2>&1 | Out-Null # pull more than expected number

$dlqEntries = @(Get-Content $dlqLogFile | Where-Object { $_.StartsWith("{") } | ForEach-Object { $_ | ConvertFrom-Json })
Write-Host "$($dlqEntries.Count) dead-lettered messages"

nats s report
nats s subjects $monitoringStreamName

$dnfCount = 0

foreach ($dlqEntry in $dlqEntries) {
    Write-Host "  Checking seq $($dlqEntry.stream_seq) on stream $($dlqEntry.stream).." -NoNewline
    
    $result = nats s get -j $dlqEntry.stream $dlqEntry.stream_seq 2>&1
    if ($LASTEXITCODE -ne 0 -or $result -match "no message found") {
        Write-Host " NOT FOUND" -ForegroundColor Red
        $dnfCount++
        continue
    }
    Write-Host " OK" -ForegroundColor Green
}

if ($dnfCount -eq 0) {
    Write-Host "`nAll dead-lettered messages were found in their respective streams." -ForegroundColor Green
}
else {
    Write-Host "`nDNFs: $dnfCount out of $($dlqEntries.Count) dead-lettered messages missing" -ForegroundColor Red
}

Write-Host "`n=== Uninstalling NATS Server ===`n" -ForegroundColor Green
& docker-compose down