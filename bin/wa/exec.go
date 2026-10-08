package main

import (
	"context"
	"encoding/json"
	"fmt"
	"math/rand"
	"os"
	"strconv"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"
)

type waE2EMessage = waE2E.Message

// Safety limits for everything that leaves the account. Approval is the
// primary gate; these are a second one against bursts.
var (
	dailyCap     = envInt("WA_DAILY_CAP", 30) // approved actions per rolling 24h
	groupCap     = envInt("WA_GROUP_CAP", 2)  // group creations per 24h
	minGap       = time.Duration(envInt("WA_MIN_GAP_S", 20)) * time.Second
	maxFileBytes = int64(envInt("WA_MAX_FILE_MB", 64)) << 20
)

func envInt(k string, d int) int {
	if v, err := strconv.Atoi(os.Getenv(k)); err == nil {
		return v
	}
	return d
}

func (d *Daemon) executorLoop(ctx context.Context) {
	t := time.NewTicker(3 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			d.runNext(ctx)
		}
	}
}

func (d *Daemon) runNext(ctx context.Context) {
	if d.db.state("temp_ban") != "" || !d.cli.IsConnected() {
		return
	}
	if next, _ := strconv.ParseInt(d.db.state("next_ok"), 10, 64); time.Now().Unix() < next {
		return
	}
	var id int64
	var action, params string
	if err := d.db.QueryRow(`SELECT id,action,params FROM outbox WHERE status='approved' ORDER BY id LIMIT 1`).Scan(&id, &action, &params); err != nil {
		return
	}
	since := time.Now().Add(-24 * time.Hour).Unix()
	var sent, groups int
	_ = d.db.QueryRow(`SELECT COUNT(*) FROM outbox WHERE status='sent' AND done_at>?`, since).Scan(&sent)
	_ = d.db.QueryRow(`SELECT COUNT(*) FROM outbox WHERE status='sent' AND action='group_create' AND done_at>?`, since).Scan(&groups)
	if sent >= dailyCap || (action == "group_create" && groups >= groupCap) {
		d.finish(id, "failed", "rate limit reached (daily cap); re-approve later")
		return
	}
	var p map[string]any
	_ = json.Unmarshal([]byte(params), &p)
	time.Sleep(time.Duration(1000+rand.Intn(3000)) * time.Millisecond) // small human-ish pause
	cctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	res, err := d.execute(cctx, action, p)
	if err != nil {
		d.finish(id, "failed", err.Error())
	} else {
		d.finish(id, "sent", res)
	}
	gap := minGap + time.Duration(rand.Intn(int(minGap/time.Second)+1))*time.Second
	d.db.setState("next_ok", strconv.FormatInt(time.Now().Add(gap).Unix(), 10))
}

func (d *Daemon) finish(id int64, status, result string) {
	d.db.Exec(`UPDATE outbox SET status=?, result=?, done_at=? WHERE id=?`, status, result, time.Now().Unix(), id)
}

func sget(p map[string]any, k string) string { s, _ := p[k].(string); return s }
func jids(p map[string]any, k string) ([]types.JID, error) {
	var out []types.JID
	arr, _ := p[k].([]any)
	for _, v := range arr {
		j, err := types.ParseJID(fmt.Sprint(v))
		if err != nil {
			return nil, err
		}
		out = append(out, j)
	}
	return out, nil
}

func (d *Daemon) execute(ctx context.Context, action string, p map[string]any) (string, error) {
	switch action {
	case "send_text":
		to, err := types.ParseJID(sget(p, "chat"))
		if err != nil {
			return "", err
		}
		msg := &waE2E.Message{Conversation: proto.String(sget(p, "text"))}
		if rid := sget(p, "reply_to"); rid != "" {
			var sender, txt string
			_ = d.db.QueryRow(`SELECT COALESCE(sender,''),COALESCE(text,'') FROM messages WHERE chat=? AND id=?`, sget(p, "chat"), rid).Scan(&sender, &txt)
			msg = &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{
				Text: proto.String(sget(p, "text")),
				ContextInfo: &waE2E.ContextInfo{StanzaID: proto.String(rid), Participant: proto.String(sender),
					QuotedMessage: &waE2E.Message{Conversation: proto.String(txt)}}}}
		}
		r, err := d.cli.SendMessage(ctx, to, msg)
		return "id " + r.ID, err
	case "send_file":
		return d.sendFile(ctx, p)
	case "react":
		to, err := types.ParseJID(sget(p, "chat"))
		if err != nil {
			return "", err
		}
		var sender string
		var fromMe int
		_ = d.db.QueryRow(`SELECT COALESCE(sender,''),from_me FROM messages WHERE chat=? AND id=?`, sget(p, "chat"), sget(p, "id")).Scan(&sender, &fromMe)
		key := &waCommon.MessageKey{RemoteJID: proto.String(to.String()), FromMe: proto.Bool(fromMe == 1), ID: proto.String(sget(p, "id"))}
		if to.Server == types.GroupServer && fromMe == 0 {
			key.Participant = proto.String(sender)
		}
		r, err := d.cli.SendMessage(ctx, to, &waE2E.Message{ReactionMessage: &waE2E.ReactionMessage{
			Key: key, Text: proto.String(sget(p, "emoji")), SenderTimestampMS: proto.Int64(time.Now().UnixMilli())}})
		return "id " + r.ID, err
	case "mark_read":
		chat, err := types.ParseJID(sget(p, "chat"))
		if err != nil {
			return "", err
		}
		var id, sender string
		var ts int64
		if err := d.db.QueryRow(`SELECT id,COALESCE(sender,chat),ts FROM messages WHERE chat=? AND from_me=0 ORDER BY ts DESC LIMIT 1`, sget(p, "chat")).Scan(&id, &sender, &ts); err != nil {
			return "", fmt.Errorf("no incoming messages to mark")
		}
		sj, _ := types.ParseJID(sender)
		return "marked", d.cli.MarkRead(ctx, []types.MessageID{id}, time.Unix(ts, 0), chat, sj)
	case "group_create":
		members, err := jids(p, "members")
		if err != nil {
			return "", err
		}
		g, err := d.cli.CreateGroup(ctx, whatsmeow.ReqCreateGroup{Name: sget(p, "name"), Participants: members})
		if err != nil {
			return "", err
		}
		d.saveGroup(g)
		return "created " + g.JID.String(), nil
	case "group_rename", "group_topic", "group_leave", "group_add", "group_remove", "group_promote", "group_demote":
		gj, err := types.ParseJID(sget(p, "group"))
		if err != nil {
			return "", err
		}
		switch action {
		case "group_rename":
			err = d.cli.SetGroupName(ctx, gj, sget(p, "name"))
		case "group_topic":
			err = d.cli.SetGroupTopic(ctx, gj, "", "", sget(p, "topic"))
		case "group_leave":
			err = d.cli.LeaveGroup(ctx, gj)
		default:
			members, e2 := jids(p, "members")
			if e2 != nil {
				return "", e2
			}
			_, err = d.cli.UpdateGroupParticipants(ctx, gj, members, whatsmeow.ParticipantChange(action[len("group_"):]))
		}
		if err == nil && action != "group_leave" {
			d.refreshGroup(gj)
		}
		return "ok", err
	}
	return "", fmt.Errorf("unknown action %q", action)
}

func (d *Daemon) sendFile(ctx context.Context, p map[string]any) (string, error) {
	to, err := types.ParseJID(sget(p, "chat"))
	if err != nil {
		return "", err
	}
	path := sget(p, "path")
	sha, size, err := fileSum(path)
	if err != nil {
		return "", err
	}
	if sha != sget(p, "sha256") {
		return "", fmt.Errorf("file changed since it was proposed (sha256 mismatch); propose it again")
	}
	if size > maxFileBytes {
		return "", fmt.Errorf("file is %d bytes, limit is %d (WA_MAX_FILE_MB)", size, maxFileBytes)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	mt := sget(p, "mime")
	if mt == "" {
		mt = "application/octet-stream"
	}
	caption := sget(p, "caption")
	var msg *waE2E.Message
	kind := sget(p, "as")
	media := map[string]whatsmeow.MediaType{"image": whatsmeow.MediaImage, "video": whatsmeow.MediaVideo,
		"audio": whatsmeow.MediaAudio, "voice": whatsmeow.MediaAudio, "document": whatsmeow.MediaDocument}[kind]
	if media == "" {
		return "", fmt.Errorf("unknown --as %q", kind)
	}
	up, err := d.cli.Upload(ctx, data, media)
	if err != nil {
		return "", fmt.Errorf("upload: %w", err)
	}
	switch kind {
	case "image":
		msg = &waE2E.Message{ImageMessage: &waE2E.ImageMessage{URL: &up.URL, DirectPath: &up.DirectPath, MediaKey: up.MediaKey,
			Mimetype: &mt, FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, FileLength: &up.FileLength, Caption: proto.String(caption)}}
	case "video":
		msg = &waE2E.Message{VideoMessage: &waE2E.VideoMessage{URL: &up.URL, DirectPath: &up.DirectPath, MediaKey: up.MediaKey,
			Mimetype: &mt, FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, FileLength: &up.FileLength, Caption: proto.String(caption)}}
	case "audio", "voice":
		if kind == "voice" {
			mt = "audio/ogg; codecs=opus" // voice notes must be Ogg/Opus
		}
		msg = &waE2E.Message{AudioMessage: &waE2E.AudioMessage{URL: &up.URL, DirectPath: &up.DirectPath, MediaKey: up.MediaKey,
			Mimetype: &mt, FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, FileLength: &up.FileLength, PTT: proto.Bool(kind == "voice")}}
	default:
		name := pathBase(path)
		msg = &waE2E.Message{DocumentMessage: &waE2E.DocumentMessage{URL: &up.URL, DirectPath: &up.DirectPath, MediaKey: up.MediaKey,
			Mimetype: &mt, FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, FileLength: &up.FileLength,
			FileName: &name, Title: &name, Caption: proto.String(caption)}}
	}
	r, err := d.cli.SendMessage(ctx, to, msg)
	return "id " + r.ID, err
}

func pathBase(p string) string {
	for i := len(p) - 1; i >= 0; i-- {
		if p[i] == '/' {
			return p[i+1:]
		}
	}
	return p
}
