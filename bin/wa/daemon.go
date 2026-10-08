package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"
)

type Daemon struct {
	cli *whatsmeow.Client
	db  *DB
	log waLog.Logger
}

func notify(urgency, title, body string) {
	_ = exec.Command("notify-send", "-a", "wa", "-u", urgency, title, body).Start()
}

// newClient opens the whatsmeow session store (separate DB from our messages).
func newClient(log waLog.Logger) (*whatsmeow.Client, *sqlstore.Container, error) {
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return nil, nil, err
	}
	sdb, err := sql.Open("sqlite", dsn(filepath.Join(dataDir, "session.db")))
	if err != nil {
		return nil, nil, err
	}
	sdb.SetMaxOpenConns(1)
	_ = os.Chmod(filepath.Join(dataDir, "session.db"), 0o600)
	container := sqlstore.NewWithDB(sdb, "sqlite3", log)
	ctx := context.Background()
	if err := container.Upgrade(ctx); err != nil {
		return nil, nil, err
	}
	dev, err := container.GetFirstDevice(ctx)
	if err != nil {
		return nil, nil, err
	}
	store.DeviceProps.Os = proto.String("wa-agent (Linux)")
	cli := whatsmeow.NewClient(dev, log)
	cli.EnableAutoReconnect = true
	return cli, container, nil
}

func runDaemon() error {
	log := waLog.Stdout("wa", "INFO", false)
	db, err := openMessages()
	if err != nil {
		return err
	}
	cli, _, err := newClient(log)
	if err != nil {
		return err
	}
	if cli.Store.ID == nil {
		return fmt.Errorf("not linked yet: run 'wa pair' in a terminal first")
	}
	d := &Daemon{cli: cli, db: db, log: log}
	cli.AddEventHandler(d.handle)
	if err := cli.Connect(); err != nil {
		return err
	}
	l, err := listenRPC(d.rpcHandle)
	if err != nil {
		return err
	}
	defer l.Close()
	ctx, cancel := context.WithCancel(context.Background())
	go d.executorLoop(ctx)
	log.Infof("daemon up as %s", cli.Store.ID)
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	cancel()
	cli.Disconnect()
	return nil
}

func (d *Daemon) event(name string) {
	d.db.setState("last_event", name+" @ "+time.Now().Format(time.RFC3339))
}

// norm maps LID addresses (WhatsApp's anonymised ids) to phone-number JIDs.
func (d *Daemon) norm(j types.JID) types.JID {
	if j.Server == types.HiddenUserServer && d.cli != nil {
		if pn, err := d.cli.Store.LIDs.GetPNForLID(context.Background(), j); err == nil && !pn.IsEmpty() {
			return pn.ToNonAD()
		}
	}
	return j.ToNonAD()
}

func (d *Daemon) handle(raw any) {
	switch e := raw.(type) {
	case *events.Message:
		d.storeMessage(e)
	case *events.HistorySync:
		d.event("history_sync")
		for _, conv := range e.Data.GetConversations() {
			cj, err := types.ParseJID(conv.GetID())
			if err != nil {
				continue
			}
			d.db.setChatName(d.norm(cj).String(), conv.GetName())
			for _, hm := range conv.GetMessages() {
				me, err := d.cli.ParseWebMessage(cj, hm.GetMessage())
				if err != nil {
					continue
				}
				d.storeMessage(me)
			}
		}
	case *events.PushName:
		d.db.putContact(d.norm(e.JID).String(), "", e.NewPushName, "")
	case *events.Contact:
		d.db.putContact(d.norm(e.JID).String(), e.Action.GetFullName(), "", "")
	case *events.AppStateSyncComplete:
		go d.syncContacts()
	case *events.JoinedGroup:
		d.saveGroup(&e.GroupInfo)
	case *events.GroupInfo:
		go d.refreshGroup(e.JID)
	case *events.Connected:
		d.db.setState("link", "connected")
		d.event("connected")
		go d.syncContacts()
	case *events.Disconnected:
		d.db.setState("link", "disconnected")
		d.event("disconnected")
	case *events.LoggedOut:
		d.db.setState("link", "logged_out")
		d.event("logged_out")
		notify("critical", "WhatsApp link lost", "wa was logged out (unlinked from the phone). Re-pair with: wa pair")
	case *events.TemporaryBan:
		msg := fmt.Sprintf("%v expires in %v", e.Code, e.Expire)
		d.db.setState("temp_ban", msg)
		d.event("temporary_ban")
		notify("critical", "WhatsApp TEMPORARY BAN", msg+"\nwa has stopped all sends.")
	case *events.ClientOutdated:
		d.db.setState("link", "client_outdated")
		notify("critical", "wa client outdated", "WhatsApp rejected this whatsmeow version. Update: ~/bin/wa/update.sh")
	case *events.StreamReplaced:
		d.event("stream_replaced")
	}
}

func (d *Daemon) storeMessage(e *events.Message) {
	m, change, txt := extractMessage(e, d.norm)
	switch change {
	case "revoke":
		d.db.markDeleted(m.Chat, m.ID)
		return
	case "edit":
		d.db.markEdited(m.Chat, m.ID, txt)
		return
	}
	if m.ID == "" {
		return
	}
	if err := d.db.putMessage(m); err != nil {
		d.log.Warnf("store message: %v", err)
		return
	}
	if m.SenderName != "" && !m.FromMe {
		d.db.putContact(m.Sender, "", m.SenderName, "")
	}
	d.db.setState("last_message", tsStr(m.TS)+" "+m.Chat)
}

func (d *Daemon) syncContacts() {
	all, err := d.cli.Store.Contacts.GetAllContacts(context.Background())
	if err != nil {
		return
	}
	for j, c := range all {
		phone := ""
		if j.Server == types.DefaultUserServer {
			phone = "+" + j.User
		}
		d.db.putContact(d.norm(j).String(), firstNonEmpty(c.FullName, c.FirstName), c.PushName, phone)
	}
}

func (d *Daemon) saveGroup(g *types.GroupInfo) {
	var ps []gpart
	for _, p := range g.Participants {
		ps = append(ps, gpart{JID: p.JID.String(), PN: p.PhoneNumber.String(), Admin: p.IsAdmin || p.IsSuperAdmin})
	}
	pj, _ := json.Marshal(ps)
	_, _ = d.db.Exec(`INSERT INTO groups(jid,name,topic,owner,created,announce,locked,participants) VALUES(?,?,?,?,?,?,?,?)
		ON CONFLICT(jid) DO UPDATE SET name=excluded.name,topic=excluded.topic,owner=excluded.owner,created=excluded.created,
		announce=excluded.announce,locked=excluded.locked,participants=excluded.participants`,
		g.JID.String(), g.Name, g.Topic, g.OwnerJID.String(), g.GroupCreated.Unix(), b2i(g.IsAnnounce), b2i(g.IsLocked), string(pj))
	d.db.setChatName(g.JID.String(), g.Name)
}

func (d *Daemon) refreshGroup(j types.JID) {
	if g, err := d.cli.GetGroupInfo(context.Background(), j); err == nil {
		d.saveGroup(g)
	}
}

func (d *Daemon) refreshAllGroups(ctx context.Context) error {
	gs, err := d.cli.GetJoinedGroups(ctx)
	if err != nil {
		return err
	}
	for _, g := range gs {
		d.saveGroup(g)
	}
	return nil
}

// ---- RPC ----

func (d *Daemon) rpcHandle(req map[string]any) (map[string]any, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 80*time.Second)
	defer cancel()
	str := func(k string) string { s, _ := req[k].(string); return s }
	switch str("cmd") {
	case "ping":
		return map[string]any{"ok": true, "connected": d.cli.IsConnected()}, nil
	case "refresh_groups":
		return map[string]any{"ok": true}, d.refreshAllGroups(ctx)
	case "invite_link":
		j, err := types.ParseJID(str("chat"))
		if err != nil {
			return nil, err
		}
		link, err := d.cli.GetGroupInviteLink(ctx, j, false)
		return map[string]any{"link": link}, err
	case "download":
		return d.download(ctx, str("chat"), str("id"), str("out"))
	}
	return nil, fmt.Errorf("unknown rpc %q", str("cmd"))
}

func safeName(s string) string {
	s = strings.Map(func(r rune) rune {
		if r == '/' || r == 0 || r == '\\' {
			return '_'
		}
		return r
	}, s)
	return strings.TrimLeft(s, ".")
}

func (d *Daemon) download(ctx context.Context, chat, id, out string) (map[string]any, error) {
	var raw []byte
	var kind, mimeT, fn string
	if err := d.db.QueryRow(`SELECT raw,kind,COALESCE(mime,''),COALESCE(filename,'') FROM messages WHERE chat=? AND id=?`, chat, id).Scan(&raw, &kind, &mimeT, &fn); err != nil || len(raw) == 0 {
		return nil, fmt.Errorf("message has no downloadable attachment")
	}
	var m = new(waE2EMessage)
	if err := proto.Unmarshal(raw, m); err != nil {
		return nil, err
	}
	data, err := d.cli.DownloadAny(ctx, m)
	if err != nil {
		return nil, fmt.Errorf("download failed (media may have expired on the server): %w", err)
	}
	dir := filepath.Join(out, safeName(strings.SplitN(chat, "@", 2)[0]))
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	name := safeName(fn)
	if name == "" {
		name = id + extFor(mimeT, kind)
	} else {
		name = id[:min(8, len(id))] + "_" + name
	}
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return nil, err
	}
	return map[string]any{"path": path, "bytes": len(data)}, nil
}

func extFor(mimeT, kind string) string {
	base := strings.SplitN(mimeT, ";", 2)[0]
	switch base {
	case "image/jpeg":
		return ".jpg"
	case "image/png":
		return ".png"
	case "image/webp":
		return ".webp"
	case "video/mp4":
		return ".mp4"
	case "audio/ogg":
		return ".ogg"
	case "audio/mpeg":
		return ".mp3"
	case "application/pdf":
		return ".pdf"
	}
	return ".bin"
}
