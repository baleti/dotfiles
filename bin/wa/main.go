// wa: a small receive-only WhatsApp client for agents, built on whatsmeow.
//
//	wa daemon            keep a linked-device session, store messages
//	wa chats|messages|new|search|contacts|group ...   read from the local DB (works offline)
//	wa send|send-file|react|group ... -> outbox; a human runs `wa approve <id>`
//
// Everything that leaves the account is queued in the outbox and needs a
// human at a terminal to approve it. See README.md.
package main

import (
	"fmt"
	"os"
	"path/filepath"
)

var (
	dataDir  = envOr("WA_DATA", filepath.Join(os.Getenv("HOME"), ".local/share/wa"))
	sockPath = envOr("WA_SOCK", filepath.Join(envOr("XDG_RUNTIME_DIR", "/tmp"), "wa.sock"))
)

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func die(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "wa: "+format+"\n", a...)
	os.Exit(1)
}

const usage = `usage: wa <command> [args]   (add --json to read commands for machine output)

read (local DB, no network):
  status                          daemon/link state and last message time
  chats [--limit N]               recent chats
  messages <chat> [--limit N] [--since 2h|2026-10-01] [--before ID]
  new [--peek]                    messages since the last 'wa new' (advances a local cursor)
  search <query> [--chat C] [--limit N]
  contacts [query]
  group list | group info <group>
  outbox [--all]                  proposed actions and their status

propose (queued; nothing is sent until a human approves):
  send <chat> <text...> [--reply-to ID]
  send-file <chat> <path> [--caption TEXT] [--as image|video|audio|voice|document]
  react <chat> <id> <emoji>
  mark-read <chat>
  group create <name> <member>... | rename <group> <name> | topic <group> <text...>
  group add|remove|promote|demote <group> <member>... | leave <group>

human only:
  pair                            link this machine (scan a QR in WhatsApp)
  approve <id>... | reject <id>... (needs a terminal)
  daemon                          run the session (systemd: wa.service)

via the running daemon:
  media <chat> <id> [--out DIR]   download and decrypt an attachment
  group refresh | group invite-link <group>
  selftest                        offline checks of storage and parsing

<chat>/<group>/<member> = JID, phone number (+44...), or a unique name fragment.`

func main() {
	if len(os.Args) < 2 {
		fmt.Println(usage)
		return
	}
	cmd, args := os.Args[1], os.Args[2:]
	var err error
	switch cmd {
	case "daemon":
		err = runDaemon()
	case "pair":
		err = runPair()
	case "help", "-h", "--help":
		fmt.Println(usage)
	default:
		err = runCLI(cmd, args)
	}
	if err != nil {
		die("%v", err)
	}
}
