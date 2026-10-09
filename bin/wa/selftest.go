package main

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
)

// selftest runs offline checks against a throwaway DB and synthetic events:
// parsing, storage, full-text search, name resolution and the outbox. It is
// what the scheduled updater runs after rebuilding against a newer whatsmeow.
func selftest() error {
	quiet = true
	dir, err := os.MkdirTemp("", "wa-selftest")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	db, err := openDB(filepath.Join(dir, "m.db"))
	if err != nil {
		return err
	}
	defer db.Close()
	norm := func(j types.JID) types.JID { return j.ToNonAD() }
	chat := types.NewJID("447700900123", types.DefaultUserServer)
	mk := func(id string, m *waE2E.Message, fromMe bool) *events.Message {
		return &events.Message{Message: m, RawMessage: m, Info: types.MessageInfo{
			MessageSource: types.MessageSource{Chat: chat, Sender: chat, IsFromMe: fromMe},
			ID:            id, PushName: "Alex", Timestamp: time.Now()}}
	}
	check := func(cond bool, what string) error {
		if !cond {
			return fmt.Errorf("selftest failed: %s", what)
		}
		return nil
	}

	img := &waE2E.Message{ImageMessage: &waE2E.ImageMessage{Caption: proto.String("site photo"), Mimetype: proto.String("image/jpeg"), FileLength: proto.Uint64(1234)}}
	for _, e := range []*events.Message{
		mk("A1", &waE2E.Message{Conversation: proto.String("hello from the drawing office")}, false),
		mk("A2", &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{Text: proto.String("reply text"), ContextInfo: &waE2E.ContextInfo{StanzaID: proto.String("A1")}}}, true),
		mk("A3", img, false),
	} {
		m, change, _ := extractMessage(e, norm)
		if err := check(change == "", "plain message treated as a change"); err != nil {
			return err
		}
		if err := db.putMessage(m); err != nil {
			return err
		}
		if err := db.putMessage(m); err != nil { // duplicate delivery must be harmless
			return err
		}
	}
	db.putContact(chat.String(), "Alex Rivera", "Alex", "+447700900123")

	var n int
	db.QueryRow(`SELECT COUNT(*) FROM messages`).Scan(&n)
	if err := check(n == 3, fmt.Sprintf("expected 3 messages, got %d", n)); err != nil {
		return err
	}
	var kind, quoted string
	var raw []byte
	db.QueryRow(`SELECT kind,COALESCE(quoted_id,''),raw FROM messages WHERE id='A3'`).Scan(&kind, &quoted, &raw)
	if err := check(kind == "image" && len(raw) > 0, "image kind and raw proto kept for download"); err != nil {
		return err
	}
	db.QueryRow(`SELECT COALESCE(quoted_id,'') FROM messages WHERE id='A2'`).Scan(&quoted)
	if err := check(quoted == "A1", "reply link stored"); err != nil {
		return err
	}

	// edit + revoke
	edit := &waE2E.Message{ProtocolMessage: &waE2E.ProtocolMessage{
		Type: waE2E.ProtocolMessage_MESSAGE_EDIT.Enum(), Key: &waCommon.MessageKey{ID: proto.String("A1")},
		EditedMessage: &waE2E.Message{Conversation: proto.String("edited zebra text")}}}
	m, change, txt := extractMessage(mk("A4", edit, false), norm)
	if err := check(change == "edit" && m.ID == "A1", "edit recognised"); err != nil {
		return err
	}
	db.markEdited(m.Chat, m.ID, txt)

	// search through the same code path the CLI uses (FTS stays in sync after the edit)
	hits, err := db.search("zebra", "", 10)
	if err := check(err == nil && len(hits) == 1, "full-text search sees edited text"); err != nil {
		return err
	}
	hits, err = db.search("drawing", chat.String(), 10)
	if err := check(err == nil && len(hits) == 0, "full-text index drops the old text"); err != nil {
		return err
	}
	hits, err = db.search("site photo", "", 10)
	if err := check(err == nil && len(hits) == 1 && hits[0].Kind == "image" && hits[0].From == "Alex Rivera", "search returns captions and resolves names"); err != nil {
		return err
	}

	// name resolution
	j, err := db.resolve("alex")
	if err := check(err == nil && j == chat.String(), "resolve by contact name"); err != nil {
		return err
	}
	j, err = db.resolve("+44 7700 900123")
	if err := check(err == nil && j == chat.String(), "resolve by phone number"); err != nil {
		return err
	}
	if _, err = db.resolve("nobody-like-this"); err == nil {
		return fmt.Errorf("selftest failed: unknown name should not resolve")
	}

	// plain sends go out without approval; group changes wait; the gate can be restored
	last := func() (id int64, status string) {
		db.QueryRow(`SELECT id,status FROM outbox ORDER BY id DESC LIMIT 1`).Scan(&id, &status)
		return
	}
	if _, err := db.addOutbox("send_text", "selftest", map[string]any{"chat": j, "text": "x"}); err != nil {
		return err
	}
	if _, st := last(); check(st == "approved", "send_text is auto-approved") != nil {
		return fmt.Errorf("selftest failed: send_text status %q", st)
	}
	if _, err := db.addOutbox("group_rename", "selftest", map[string]any{"chat": j, "name": "x"}); err != nil {
		return err
	}
	gid, st := last()
	if err := check(st == "pending", "group actions still start pending"); err != nil {
		return err
	}
	os.Setenv("WA_REQUIRE_APPROVAL", "1")
	if _, err := db.addOutbox("send_text", "selftest", map[string]any{"chat": j, "text": "x"}); err != nil {
		return err
	}
	os.Unsetenv("WA_REQUIRE_APPROVAL")
	if _, st := last(); check(st == "pending", "WA_REQUIRE_APPROVAL=1 restores the gate") != nil {
		return fmt.Errorf("selftest failed: gated send_text status %q", st)
	}
	if !stdinIsTerminal() {
		if err := check(cmdApprove(db, "approve", args{pos: []string{fmt.Sprint(gid)}}) != nil, "approve must refuse without a terminal"); err != nil {
			return err
		}
	}
	fmt.Println("selftest ok")
	return nil
}

func stdinIsTerminal() bool {
	fi, err := os.Stdin.Stat()
	return err == nil && fi.Mode()&os.ModeCharDevice != 0
}
