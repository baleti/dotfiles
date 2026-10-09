package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"mime"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"golang.org/x/term"
)

// args splits positional arguments from --flags. Flags in withVal take a value.
type args struct {
	pos  []string
	flag map[string]string
}

func parseArgs(in []string, withVal ...string) args {
	a := args{flag: map[string]string{}}
	hv := map[string]bool{}
	for _, v := range withVal {
		hv[v] = true
	}
	for i := 0; i < len(in); i++ {
		s := in[i]
		if strings.HasPrefix(s, "--") {
			k := s[2:]
			if hv[k] && i+1 < len(in) {
				a.flag[k] = in[i+1]
				i++
			} else {
				a.flag[k] = "1"
			}
		} else {
			a.pos = append(a.pos, s)
		}
	}
	return a
}

func (a args) has(k string) bool { return a.flag[k] != "" }
func (a args) num(k string, d int) int {
	if v, err := strconv.Atoi(a.flag[k]); err == nil {
		return v
	}
	return d
}

func emit(asJSON bool, v any, plain func()) {
	if asJSON {
		b, _ := json.MarshalIndent(v, "", " ")
		fmt.Println(string(b))
		return
	}
	plain()
}

// resolve turns a JID, phone number or name fragment into a JID.
func (d *DB) resolve(q string) (string, error) {
	q = strings.TrimSpace(q)
	if strings.Contains(q, "@") {
		return q, nil
	}
	digits := strings.NewReplacer("+", "", " ", "", "-", "", "(", "", ")", "").Replace(q)
	if _, err := strconv.ParseUint(digits, 10, 64); err == nil && len(digits) >= 7 {
		return digits + "@s.whatsapp.net", nil
	}
	like := "%" + q + "%"
	rows, err := d.Query(`SELECT jid FROM chats WHERE name LIKE ? COLLATE NOCASE
		UNION SELECT jid FROM contacts WHERE name LIKE ? COLLATE NOCASE OR push_name LIKE ? COLLATE NOCASE
		UNION SELECT jid FROM groups WHERE name LIKE ? COLLATE NOCASE`, like, like, like, like)
	if err != nil {
		return "", err
	}
	var jids []string
	for rows.Next() {
		var j string
		rows.Scan(&j)
		jids = append(jids, j)
	}
	rows.Close()
	switch len(jids) {
	case 0:
		return "", fmt.Errorf("no chat or contact matches %q", q)
	case 1:
		return jids[0], nil
	}
	var names []string
	for i, j := range jids {
		if i >= 8 {
			break
		}
		names = append(names, fmt.Sprintf("%s (%s)", d.displayName(j), j))
	}
	return "", fmt.Errorf("%q is ambiguous: %s", q, strings.Join(names, "; "))
}

func (d *DB) resolveMsg(chat, prefix string) (string, error) {
	rows, err := d.Query(`SELECT id FROM messages WHERE chat=? AND id LIKE ?`, chat, prefix+"%")
	if err != nil {
		return "", err
	}
	var ids []string
	for rows.Next() {
		var id string
		rows.Scan(&id)
		ids = append(ids, id)
	}
	rows.Close()
	if len(ids) != 1 {
		return "", fmt.Errorf("message id %q matches %d messages in that chat", prefix, len(ids))
	}
	return ids[0], nil
}

func parseSince(s string) (int64, error) {
	if s == "" {
		return 0, nil
	}
	if dur, err := time.ParseDuration(s); err == nil {
		return time.Now().Add(-dur).Unix(), nil
	}
	for _, layout := range []string{"2006-01-02 15:04", "2006-01-02"} {
		if t, err := time.ParseInLocation(layout, s, time.Local); err == nil {
			return t.Unix(), nil
		}
	}
	return 0, fmt.Errorf("bad --since %q (use 2h, 30m or 2026-10-01)", s)
}

type outMsg struct {
	Chat     string `json:"chat"`
	ChatName string `json:"chat_name"`
	ID       string `json:"id"`
	Time     string `json:"time"`
	TS       int64  `json:"ts"`
	From     string `json:"from"`
	FromMe   bool   `json:"from_me"`
	Kind     string `json:"kind"`
	Text     string `json:"text"`
	File     string `json:"file,omitempty"`
	Quoted   string `json:"reply_to,omitempty"`
	Edited   bool   `json:"edited,omitempty"`
	Deleted  bool   `json:"deleted,omitempty"`
}

const msgCols = `chat,id,COALESCE(sender,''),COALESCE(sender_name,''),ts,from_me,COALESCE(kind,''),COALESCE(text,''),COALESCE(mime,''),COALESCE(filename,''),COALESCE(quoted_id,''),edited,deleted`

// scanMsgs drains the rows before resolving names: the DB has a single
// connection, so a nested query while rows are open would deadlock.
func (d *DB) scanMsgs(rows interface {
	Next() bool
	Scan(...any) error
	Close() error
}) []outMsg {
	type rec struct {
		m                        outMsg
		sender, sname, mimeT, fn string
		fromMe, ed, del          int
	}
	var recs []rec
	for rows.Next() {
		var r rec
		rows.Scan(&r.m.Chat, &r.m.ID, &r.sender, &r.sname, &r.m.TS, &r.fromMe, &r.m.Kind, &r.m.Text, &r.mimeT, &r.fn, &r.m.Quoted, &r.ed, &r.del)
		recs = append(recs, r)
	}
	rows.Close()
	out := make([]outMsg, 0, len(recs))
	for _, r := range recs {
		m := r.m
		m.FromMe, m.Edited, m.Deleted = r.fromMe == 1, r.ed == 1, r.del == 1
		m.Time = tsStr(m.TS)
		m.ChatName = d.displayName(m.Chat)
		switch {
		case m.FromMe:
			m.From = "me"
		default:
			// saved contact name > push name carried on the message > best guess
			m.From = firstNonEmpty(d.savedName(r.sender), r.sname, d.displayName(r.sender))
		}
		if m.Kind != "text" && m.Kind != "" {
			m.File = strings.TrimSpace(r.fn + " " + r.mimeT)
		}
		out = append(out, m)
	}
	return out
}

func printMsgs(ms []outMsg, showChat bool) {
	for _, m := range ms {
		tag := ""
		if m.Kind != "text" && m.Kind != "" {
			tag = "[" + m.Kind
			if m.File != "" {
				tag += ": " + m.File
			}
			tag += "] "
		}
		flags := ""
		if m.Edited {
			flags += " (edited)"
		}
		if m.Deleted {
			flags += " (deleted)"
		}
		chat := ""
		if showChat {
			chat = "[" + m.ChatName + "] "
		}
		short := m.ID
		if len(short) > 8 {
			short = short[:8]
		}
		fmt.Printf("%s #%s %s%s: %s%s%s\n", m.Time, short, chat, m.From, tag, m.Text, flags)
	}
}

func runCLI(cmd string, in []string) error {
	// commands that never touch the DB first
	switch cmd {
	case "selftest":
		return selftest()
	}
	db, err := openMessages()
	if err != nil {
		return err
	}
	defer db.Close()
	a := parseArgs(in, "limit", "since", "before", "chat", "caption", "as", "reply-to", "out")
	js := a.has("json")

	switch cmd {
	case "status":
		return cmdStatus(db, js)
	case "chats":
		rows, err := db.Query(`SELECT jid,is_group,last_ts FROM chats WHERE last_ts>0 ORDER BY last_ts DESC LIMIT ?`, a.num("limit", 30))
		if err != nil {
			return err
		}
		type ch struct {
			JID, Name string
			Group     bool
			Last      string
		}
		var out []ch
		for rows.Next() {
			var c ch
			var g int
			var ts int64
			rows.Scan(&c.JID, &g, &ts)
			c.Group, c.Last = g == 1, tsStr(ts)
			out = append(out, c)
		}
		rows.Close()
		for i := range out {
			out[i].Name = db.displayName(out[i].JID)
		}
		emit(js, out, func() {
			for _, c := range out {
				g := ""
				if c.Group {
					g = " (group)"
				}
				fmt.Printf("%s  %s%s  <%s>\n", c.Last, c.Name, g, c.JID)
			}
		})
	case "messages":
		if len(a.pos) < 1 {
			return fmt.Errorf("usage: wa messages <chat> [--limit N] [--since 2h] [--before ID]")
		}
		jid, err := db.resolve(a.pos[0])
		if err != nil {
			return err
		}
		since, err := parseSince(a.flag["since"])
		if err != nil {
			return err
		}
		q := `SELECT ` + msgCols + ` FROM messages WHERE chat=? AND ts>=?`
		qa := []any{jid, since}
		if b := a.flag["before"]; b != "" {
			id, err := db.resolveMsg(jid, b)
			if err != nil {
				return err
			}
			q += ` AND seq < (SELECT seq FROM messages WHERE chat=? AND id=?)`
			qa = append(qa, jid, id)
		}
		q += ` ORDER BY ts DESC, seq DESC LIMIT ?`
		qa = append(qa, a.num("limit", 30))
		rows, err := db.Query(q, qa...)
		if err != nil {
			return err
		}
		ms := db.scanMsgs(rows)
		for i, j := 0, len(ms)-1; i < j; i, j = i+1, j-1 {
			ms[i], ms[j] = ms[j], ms[i]
		}
		emit(js, ms, func() { printMsgs(ms, false) })
	case "new":
		cur, _ := strconv.ParseInt(db.state("new_cursor"), 10, 64)
		if cur == 0 {
			_ = db.QueryRow(`SELECT COALESCE(MIN(seq),1)-1 FROM messages WHERE ts>?`, time.Now().Add(-24*time.Hour).Unix()).Scan(&cur)
		}
		var maxSeq int64
		_ = db.QueryRow(`SELECT COALESCE(MAX(seq),0) FROM messages`).Scan(&maxSeq)
		rows, err := db.Query(`SELECT `+msgCols+` FROM messages WHERE seq>? AND from_me=0 AND deleted=0 ORDER BY seq`, cur)
		if err != nil {
			return err
		}
		ms := db.scanMsgs(rows)
		if !a.has("peek") {
			db.setState("new_cursor", strconv.FormatInt(maxSeq, 10))
		}
		emit(js, ms, func() {
			if len(ms) == 0 {
				fmt.Println("(nothing new)")
			}
			printMsgs(ms, true)
		})
	case "search":
		if len(a.pos) < 1 {
			return fmt.Errorf("usage: wa search <query> [--chat C] [--limit N]")
		}
		chatJID := ""
		if c := a.flag["chat"]; c != "" {
			j, err := db.resolve(c)
			if err != nil {
				return err
			}
			chatJID = j
		}
		ms, err := db.search(strings.Join(a.pos, " "), chatJID, a.num("limit", 20))
		if err != nil {
			return err
		}
		emit(js, ms, func() { printMsgs(ms, true) })
	case "contacts":
		like := "%"
		if len(a.pos) > 0 {
			like = "%" + strings.Join(a.pos, " ") + "%"
		}
		rows, err := db.Query(`SELECT jid,COALESCE(name,''),COALESCE(push_name,''),COALESCE(phone,'') FROM contacts
			WHERE name LIKE ? COLLATE NOCASE OR push_name LIKE ? COLLATE NOCASE OR phone LIKE ? ORDER BY COALESCE(NULLIF(name,''),push_name) LIMIT ?`, like, like, like, a.num("limit", 50))
		if err != nil {
			return err
		}
		type ct struct{ JID, Name, Push, Phone string }
		var out []ct
		for rows.Next() {
			var c ct
			rows.Scan(&c.JID, &c.Name, &c.Push, &c.Phone)
			out = append(out, c)
		}
		rows.Close()
		emit(js, out, func() {
			for _, c := range out {
				fmt.Printf("%s  %s  <%s>\n", firstNonEmpty(c.Name, c.Push+" (~)"), c.Phone, c.JID)
			}
		})
	case "outbox":
		return cmdOutbox(db, a, js)
	case "send", "send-file", "react", "mark-read":
		return proposeBasic(db, cmd, a)
	case "group":
		return cmdGroup(db, a, js)
	case "approve", "reject":
		return cmdApprove(db, cmd, a)
	case "media":
		if len(a.pos) < 2 {
			return fmt.Errorf("usage: wa media <chat> <id> [--out DIR]")
		}
		jid, err := db.resolve(a.pos[0])
		if err != nil {
			return err
		}
		id, err := db.resolveMsg(jid, a.pos[1])
		if err != nil {
			return err
		}
		out := a.flag["out"]
		if out == "" {
			out = filepath.Join(dataDir, "media")
		}
		res, err := rpc(map[string]any{"cmd": "download", "chat": jid, "id": id, "out": out})
		if err != nil {
			return err
		}
		fmt.Println(res["path"])
	default:
		return fmt.Errorf("unknown command %q (try: wa help)", cmd)
	}
	return nil
}

func firstNonEmpty(s ...string) string {
	for _, v := range s {
		if strings.TrimSpace(v) != "" && v != " (~)" {
			return v
		}
	}
	return ""
}

func cmdStatus(db *DB, js bool) error {
	st := map[string]any{
		"link":         db.state("link"),
		"last_event":   db.state("last_event"),
		"last_message": db.state("last_message"),
		"temp_ban":     db.state("temp_ban"),
	}
	var n int
	_ = db.QueryRow(`SELECT COUNT(*) FROM messages`).Scan(&n)
	st["messages"] = n
	_, err := rpc(map[string]any{"cmd": "ping"})
	st["daemon"] = err == nil
	emit(js, st, func() {
		fmt.Printf("daemon: %v  link: %s  messages: %d\nlast event: %s\nlast message: %s\n",
			st["daemon"], st["link"], n, st["last_event"], st["last_message"])
		if b := db.state("temp_ban"); b != "" {
			fmt.Println("TEMPORARY BAN:", b)
		}
	})
	return nil
}

// quiet silences notifications and output (set by selftest).
var quiet bool

// ---- outbox ----

// autoSend lists the actions that go out without a human approving each one:
// plain messages, files and reactions. Group changes and read receipts still wait
// for `wa approve`. Set WA_REQUIRE_APPROVAL=1 to gate everything again. The
// daemon's rate limits and daily caps apply either way.
var autoSend = map[string]bool{"send_text": true, "send_file": true, "react": true}

func (d *DB) addOutbox(action, summary string, params map[string]any) (int64, error) {
	b, _ := json.Marshal(params)
	auto := autoSend[action] && os.Getenv("WA_REQUIRE_APPROVAL") == ""
	status, now := "pending", time.Now().Unix()
	var approvedAt any
	if auto {
		status, approvedAt = "approved", now
	}
	r, err := d.Exec(`INSERT INTO outbox(created,action,summary,params,status,approved_at) VALUES(?,?,?,?,?,?)`,
		now, action, summary, string(b), status, approvedAt)
	if err != nil {
		return 0, err
	}
	id, _ := r.LastInsertId()
	if !quiet {
		if auto {
			_ = exec.Command("notify-send", "-a", "wa", "WhatsApp sending", fmt.Sprintf("#%d %s", id, summary)).Start()
			fmt.Printf("queued #%d: %s\nthe daemon sends it shortly (wa outbox --all)\n", id, summary)
		} else {
			_ = exec.Command("notify-send", "-a", "wa", "WhatsApp action awaiting approval", fmt.Sprintf("#%d %s\nrun: wa approve %d", id, summary, id)).Start()
			fmt.Printf("queued #%d: %s\nnothing is sent until a human runs: wa approve %d\n", id, summary, id)
		}
	}
	return id, nil
}

func fileSum(path string) (string, int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	h := sha256.New()
	n, err := io.Copy(h, f)
	return hex.EncodeToString(h.Sum(nil)), n, err
}

func proposeBasic(db *DB, cmd string, a args) error {
	need := map[string]int{"send": 2, "send-file": 2, "react": 3, "mark-read": 1}[cmd]
	if len(a.pos) < need {
		return fmt.Errorf("usage: see 'wa help' for %s", cmd)
	}
	jid, err := db.resolve(a.pos[0])
	if err != nil {
		return err
	}
	who := fmt.Sprintf("%s <%s>", db.displayName(jid), jid)
	switch cmd {
	case "send":
		text := strings.Join(a.pos[1:], " ")
		p := map[string]any{"chat": jid, "text": text}
		sum := fmt.Sprintf("send to %s: %q", who, text)
		if r := a.flag["reply-to"]; r != "" {
			id, err := db.resolveMsg(jid, r)
			if err != nil {
				return err
			}
			p["reply_to"] = id
			sum += " (reply to #" + id[:min(8, len(id))] + ")"
		}
		_, err = db.addOutbox("send_text", sum, p)
	case "send-file":
		path, err2 := filepath.Abs(a.pos[1])
		if err2 != nil {
			return err2
		}
		sha, size, err2 := fileSum(path)
		if err2 != nil {
			return err2
		}
		mt := mime.TypeByExtension(strings.ToLower(filepath.Ext(path)))
		kind := a.flag["as"]
		if kind == "" {
			switch {
			case strings.HasPrefix(mt, "image/"):
				kind = "image"
			case strings.HasPrefix(mt, "video/"):
				kind = "video"
			case strings.HasPrefix(mt, "audio/"):
				kind = "audio"
			default:
				kind = "document"
			}
		}
		p := map[string]any{"chat": jid, "path": path, "sha256": sha, "size": size, "mime": mt, "as": kind, "caption": a.flag["caption"]}
		_, err = db.addOutbox("send_file", fmt.Sprintf("send %s %s (%d bytes, sha256 %s…) to %s caption %q", kind, filepath.Base(path), size, sha[:12], who, a.flag["caption"]), p)
	case "react":
		id, err2 := db.resolveMsg(jid, a.pos[1])
		if err2 != nil {
			return err2
		}
		_, err = db.addOutbox("react", fmt.Sprintf("react %s to #%s in %s", a.pos[2], id[:min(8, len(id))], who), map[string]any{"chat": jid, "id": id, "emoji": a.pos[2]})
	case "mark-read":
		_, err = db.addOutbox("mark_read", "mark chat read (sends read receipts) in "+who, map[string]any{"chat": jid})
	}
	return err
}

func cmdOutbox(db *DB, a args, js bool) error {
	q := `SELECT id,created,action,summary,status,COALESCE(result,'') FROM outbox`
	if !a.has("all") {
		q += ` WHERE status IN ('pending','approved')`
	}
	rows, err := db.Query(q+` ORDER BY id DESC LIMIT ?`, a.num("limit", 30))
	if err != nil {
		return err
	}
	defer rows.Close()
	type ob struct {
		ID                                    int64
		Time, Action, Summary, Status, Result string
	}
	var out []ob
	for rows.Next() {
		var o ob
		var ts int64
		rows.Scan(&o.ID, &ts, &o.Action, &o.Summary, &o.Status, &o.Result)
		o.Time = tsStr(ts)
		out = append(out, o)
	}
	emit(js, out, func() {
		if len(out) == 0 {
			fmt.Println("(outbox empty)")
		}
		for _, o := range out {
			fmt.Printf("#%d %s [%s] %s %s\n", o.ID, o.Time, o.Status, o.Summary, o.Result)
		}
	})
	return nil
}

// cmdApprove requires a human at a terminal: it prints exactly what will
// happen and waits for a typed "yes" on /dev/tty. This is a guard against
// agents acting by accident, not a security boundary against code running as
// the same user (which could edit the DB directly).
func cmdApprove(db *DB, cmd string, a args) error {
	if !term.IsTerminal(int(os.Stdin.Fd())) || !term.IsTerminal(int(os.Stdout.Fd())) {
		return fmt.Errorf("%s needs an interactive terminal (a human must run it)", cmd)
	}
	tty, err := os.Open("/dev/tty")
	if err != nil {
		return err
	}
	defer tty.Close()
	rd := bufio.NewReader(tty)
	for _, s := range a.pos {
		id, err := strconv.ParseInt(strings.TrimPrefix(s, "#"), 10, 64)
		if err != nil {
			return fmt.Errorf("bad id %q", s)
		}
		var action, summary, status, params string
		if err := db.QueryRow(`SELECT action,summary,status,params FROM outbox WHERE id=?`, id).Scan(&action, &summary, &status, &params); err != nil {
			return fmt.Errorf("no outbox entry #%d", id)
		}
		if status != "pending" {
			fmt.Printf("#%d is already %s\n", id, status)
			continue
		}
		if cmd == "reject" {
			db.Exec(`UPDATE outbox SET status='rejected', done_at=? WHERE id=?`, time.Now().Unix(), id)
			fmt.Printf("#%d rejected\n", id)
			continue
		}
		fmt.Printf("\n#%d  %s\n  %s\n  params: %s\napprove? type yes: ", id, action, summary, params)
		line, _ := rd.ReadString('\n')
		if strings.TrimSpace(line) != "yes" {
			fmt.Println("skipped")
			continue
		}
		db.Exec(`UPDATE outbox SET status='approved', approved_at=? WHERE id=?`, time.Now().Unix(), id)
		fmt.Printf("#%d approved; the daemon sends it shortly (wa outbox --all)\n", id)
	}
	return nil
}

// search runs a prefix-AND full-text query, newest first.
func (d *DB) search(query, chat string, limit int) ([]outMsg, error) {
	var terms []string
	for _, w := range strings.Fields(query) {
		terms = append(terms, `"`+strings.ReplaceAll(w, `"`, `""`)+`"*`)
	}
	q := `SELECT ` + msgCols + ` FROM messages WHERE rowid IN (SELECT rowid FROM messages_fts WHERE messages_fts MATCH ?)`
	qa := []any{strings.Join(terms, " ")}
	if chat != "" {
		q += ` AND chat=?`
		qa = append(qa, chat)
	}
	rows, err := d.Query(q+` ORDER BY ts DESC LIMIT ?`, append(qa, limit)...)
	if err != nil {
		return nil, err
	}
	return d.scanMsgs(rows), nil
}
