package main

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

const schema = `
CREATE TABLE IF NOT EXISTS chats(
  jid TEXT PRIMARY KEY, name TEXT, is_group INTEGER DEFAULT 0, last_ts INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS contacts(
  jid TEXT PRIMARY KEY, name TEXT, push_name TEXT, phone TEXT);
CREATE TABLE IF NOT EXISTS messages(
  chat TEXT NOT NULL, id TEXT NOT NULL, sender TEXT, sender_name TEXT,
  ts INTEGER NOT NULL, from_me INTEGER DEFAULT 0,
  kind TEXT, text TEXT, mime TEXT, filename TEXT, size INTEGER,
  quoted_id TEXT, edited INTEGER DEFAULT 0, deleted INTEGER DEFAULT 0,
  raw BLOB, seq INTEGER,
  PRIMARY KEY(chat,id));
CREATE INDEX IF NOT EXISTS messages_ts ON messages(chat, ts);
CREATE INDEX IF NOT EXISTS messages_seq ON messages(seq);
CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(text, content='messages', content_rowid='rowid');
CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
  INSERT INTO messages_fts(rowid,text) VALUES (new.rowid, new.text); END;
CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
  INSERT INTO messages_fts(messages_fts,rowid,text) VALUES('delete', old.rowid, old.text); END;
CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE OF text ON messages BEGIN
  INSERT INTO messages_fts(messages_fts,rowid,text) VALUES('delete', old.rowid, old.text);
  INSERT INTO messages_fts(rowid,text) VALUES (new.rowid, new.text); END;
CREATE TABLE IF NOT EXISTS groups(
  jid TEXT PRIMARY KEY, name TEXT, topic TEXT, owner TEXT, created INTEGER,
  announce INTEGER DEFAULT 0, locked INTEGER DEFAULT 0, participants TEXT);
CREATE TABLE IF NOT EXISTS outbox(
  id INTEGER PRIMARY KEY AUTOINCREMENT, created INTEGER, action TEXT, summary TEXT, params TEXT,
  status TEXT DEFAULT 'pending', result TEXT, approved_at INTEGER, done_at INTEGER);
CREATE TABLE IF NOT EXISTS state(k TEXT PRIMARY KEY, v TEXT);
`

type DB struct{ *sql.DB }

func dsn(path string) string {
	return "file:" + path + "?_pragma=foreign_keys(1)&_pragma=busy_timeout(10000)&_pragma=journal_mode(WAL)"
}

func openDB(path string) (*DB, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite", dsn(path))
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1) // one writer, keeps WAL simple
	if _, err := db.Exec(schema); err != nil {
		return nil, fmt.Errorf("schema: %w", err)
	}
	_ = os.Chmod(path, 0o600)
	return &DB{db}, nil
}

func openMessages() (*DB, error) { return openDB(filepath.Join(dataDir, "messages.db")) }

type Msg struct {
	Chat, ID, Sender, SenderName string
	TS                           int64
	FromMe                       bool
	Kind, Text, Mime, Filename   string
	Size                         int64
	QuotedID                     string
	Edited, Deleted              bool
	Raw                          []byte
}

func (d *DB) state(k string) string {
	var v string
	_ = d.QueryRow(`SELECT v FROM state WHERE k=?`, k).Scan(&v)
	return v
}
func (d *DB) setState(k, v string) {
	_, _ = d.Exec(`INSERT INTO state(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v`, k, v)
}

// putMessage inserts a message; a repeat of the same (chat,id) is ignored so
// history sync and live delivery can overlap.
func (d *DB) putMessage(m Msg) error {
	_, err := d.Exec(`INSERT OR IGNORE INTO messages(chat,id,sender,sender_name,ts,from_me,kind,text,mime,filename,size,quoted_id,raw,seq)
		VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?, (SELECT COALESCE(MAX(seq),0)+1 FROM messages))`,
		m.Chat, m.ID, m.Sender, m.SenderName, m.TS, b2i(m.FromMe), m.Kind, m.Text, m.Mime, m.Filename, m.Size, m.QuotedID, m.Raw)
	if err != nil {
		return err
	}
	_, err = d.Exec(`INSERT INTO chats(jid,is_group,last_ts) VALUES(?,?,?)
		ON CONFLICT(jid) DO UPDATE SET last_ts=MAX(last_ts, excluded.last_ts)`,
		m.Chat, b2i(strings.HasSuffix(m.Chat, "@g.us")), m.TS)
	return err
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}

func (d *DB) setChatName(jid, name string) {
	if name == "" {
		return
	}
	_, _ = d.Exec(`INSERT INTO chats(jid,name,is_group) VALUES(?,?,?) ON CONFLICT(jid) DO UPDATE SET name=excluded.name`,
		jid, name, b2i(strings.HasSuffix(jid, "@g.us")))
}

func (d *DB) putContact(jid, name, push, phone string) {
	_, _ = d.Exec(`INSERT INTO contacts(jid,name,push_name,phone) VALUES(?,?,?,?)
		ON CONFLICT(jid) DO UPDATE SET name=CASE WHEN excluded.name!='' THEN excluded.name ELSE name END,
		push_name=CASE WHEN excluded.push_name!='' THEN excluded.push_name ELSE push_name END,
		phone=CASE WHEN excluded.phone!='' THEN excluded.phone ELSE phone END`, jid, name, push, phone)
}

func (d *DB) markEdited(chat, id, text string) {
	_, _ = d.Exec(`UPDATE messages SET text=?, edited=1 WHERE chat=? AND id=?`, text, chat, id)
}
func (d *DB) markDeleted(chat, id string) {
	_, _ = d.Exec(`UPDATE messages SET deleted=1 WHERE chat=? AND id=?`, chat, id)
}

// displayName: saved contact name > push name > phone/jid user part.
func (d *DB) displayName(jid string) string {
	var name, push string
	_ = d.QueryRow(`SELECT COALESCE(name,''),COALESCE(push_name,'') FROM contacts WHERE jid=?`, jid).Scan(&name, &push)
	if name != "" {
		return name
	}
	var cn string
	_ = d.QueryRow(`SELECT COALESCE(name,'') FROM chats WHERE jid=?`, jid).Scan(&cn)
	if cn != "" {
		return cn
	}
	if push != "" {
		return push + " (~)"
	}
	return strings.SplitN(jid, "@", 2)[0]
}

func tsStr(ts int64) string { return time.Unix(ts, 0).Format("2006-01-02 15:04") }

// savedName is the name from the user's own contacts, if any.
func (d *DB) savedName(jid string) string {
	var name string
	_ = d.QueryRow(`SELECT COALESCE(name,'') FROM contacts WHERE jid=?`, jid).Scan(&name)
	return name
}
