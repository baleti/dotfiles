package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/mdp/qrterminal/v3"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
)

// runPair links this machine as a companion device. It stays connected for a
// short while afterwards so the phone's initial history sync gets stored.
func runPair() error {
	log := waLog.Stdout("wa", "WARN", false)
	cli, _, err := newClient(log)
	if err != nil {
		return err
	}
	if cli.Store.ID != nil {
		return fmt.Errorf("already linked as %s (to re-link, unlink it on the phone and delete %s/session.db)", cli.Store.ID, dataDir)
	}
	db, err := openMessages()
	if err != nil {
		return err
	}
	d := &Daemon{cli: cli, db: db, log: log}
	lastSync := time.Now()
	cli.AddEventHandler(func(e any) {
		if _, ok := e.(*events.HistorySync); ok {
			lastSync = time.Now()
		}
		d.handle(e)
	})
	ctx := context.Background()
	qrs, err := cli.GetQRChannel(ctx)
	if err != nil {
		return err
	}
	if err := cli.Connect(); err != nil {
		return err
	}
	fmt.Println("On the phone: WhatsApp > Linked devices > Link a device, then scan:")
	for q := range qrs {
		switch q.Event {
		case "code":
			qrterminal.GenerateHalfBlock(q.Code, qrterminal.L, os.Stdout)
		case "success":
			fmt.Println("linked. keeping the session open for the initial history sync...")
			deadline := time.Now().Add(3 * time.Minute)
			for time.Now().Before(deadline) && time.Since(lastSync) < 25*time.Second {
				time.Sleep(2 * time.Second)
			}
			cli.Disconnect()
			fmt.Println("done. start the daemon: systemctl --user enable --now wa")
			return nil
		case "timeout", "err-client-outdated", "error":
			cli.Disconnect()
			return fmt.Errorf("pairing %s", q.Event)
		}
	}
	return nil
}
