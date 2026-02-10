package main

import (
	"context"
	"flag"
	"log"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

func main() {
	stream := flag.String("stream", "", "JS Stream to consume")
	consumerName := flag.String("consumer", "", "JS Consumer to subscribe to")
	msgs := flag.Uint64("msgs", 100, "Number of messages to consume (default: 100)")
	maxDeliver := flag.Uint64("max-deliver", 3, "Maximum number of delivery attempts (default: 3)")
	gracePeriod := flag.Duration("grace-period", 30*time.Second, "Grace period to wait before exiting after expected number of messages have been consumed (default: 30s)")

	flag.Parse()

	url := nats.DefaultURL

	slog.Info("Consumer started, connecting to NATS", "server", url, "stream", *stream, "consumer", *consumerName, "msgs", *msgs, "max-deliver", *maxDeliver, "grace-period", gracePeriod.String())

	connection, err := nats.Connect(url)
	if err != nil {
		log.Fatal(err)
	}
	defer connection.Close()

	slog.Info("Connected to NATS")

	jetStream, err := jetstream.New(connection)
	if err != nil {
		log.Fatal(err)
	}

	slog.Info("Connected to JetStream")

	exit := make(chan os.Signal, 1)
	signal.Notify(exit, os.Interrupt, syscall.SIGTERM)

	consumer, err := jetStream.Consumer(context.Background(), *stream, *consumerName)
	if err != nil {
		log.Fatal(err)
	}

	slog.Info("Connected to Consumer")

	consumerCtx, err := consumer.Consume(func(msg jetstream.Msg) {
		meta, err := msg.Metadata()
		if err != nil {
			slog.Error("failed to get msg metadata", "err", err)
			err = msg.Nak()
			if err != nil {
				slog.Error("failed to NACK msg", "err", err)
			}
			return
		}

		ids := msg.Headers()["Nats-Msg-Id"]
		if len(ids) == 0 {
			slog.Warn("msg without ID", "stream", meta.Stream, "stream-seq", meta.Sequence.Stream, "consumer-seq", meta.Sequence.Consumer, "subject", msg.Subject())
		} else if len(ids) != 1 {
			slog.Warn("msg with multiple IDs", "stream", meta.Stream, "stream-seq", meta.Sequence.Stream, "consumer-seq", meta.Sequence.Consumer, "subject", msg.Subject())
		}

		slog.Info("msg received", "stream", meta.Stream, "stream-seq", meta.Sequence.Stream, "consumer-seq", meta.Sequence.Consumer, "subject", msg.Subject(), "id", ids[0], "delivered", meta.NumDelivered)

		// fail every 10th message
		if meta.Sequence.Stream%10 == 0 {
			slog.Error("Processing failed", "stream-seq", meta.Sequence.Stream, "id", ids[0])
			if meta.Sequence.Stream == *msgs && meta.NumDelivered == *maxDeliver {
				slog.Info("Expected number of messages to consume reached, sleeping before exiting", "duration", gracePeriod.String())
				time.Sleep(*gracePeriod)
				exit <- os.Interrupt
			}
			return
		}

		err = msg.Ack()
		if err != nil {
			slog.Error("failed to ACK msg", "err", err, "consumer-seq", meta.Sequence.Consumer, "stream-seq", meta.Sequence.Stream, "id", ids[0])
		}

		slog.Info("Processing succeeded", "stream-seq", meta.Sequence.Stream, "id", ids[0])
	})
	if err != nil {
		log.Fatal(err)
	}
	defer func() {
		consumerCtx.Drain()
		consumerCtx.Stop()
	}()

	signal := <-exit

	slog.Info("Exit signal received, exiting", "signal", signal)
}
