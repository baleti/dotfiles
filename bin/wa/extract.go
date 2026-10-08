package main

import (
	"fmt"
	"strings"

	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
)

// describe reduces a WhatsApp message to what agents need: kind, text and file info.
func describe(m *waE2E.Message) (kind, text, mime, fname string, size int64, quoted string) {
	ctxInfo := func(ci *waE2E.ContextInfo) {
		if ci != nil && quoted == "" {
			quoted = ci.GetStanzaID()
		}
	}
	switch {
	case m == nil:
		return "other", "", "", "", 0, ""
	case m.GetConversation() != "":
		return "text", m.GetConversation(), "", "", 0, ""
	case m.GetExtendedTextMessage() != nil:
		e := m.GetExtendedTextMessage()
		ctxInfo(e.GetContextInfo())
		return "text", e.GetText(), "", "", 0, quoted
	case m.GetImageMessage() != nil:
		i := m.GetImageMessage()
		ctxInfo(i.GetContextInfo())
		return "image", i.GetCaption(), i.GetMimetype(), "", int64(i.GetFileLength()), quoted
	case m.GetVideoMessage() != nil:
		v := m.GetVideoMessage()
		ctxInfo(v.GetContextInfo())
		return "video", v.GetCaption(), v.GetMimetype(), "", int64(v.GetFileLength()), quoted
	case m.GetAudioMessage() != nil:
		a := m.GetAudioMessage()
		ctxInfo(a.GetContextInfo())
		k := "audio"
		if a.GetPTT() {
			k = "voice"
		}
		return k, "", a.GetMimetype(), "", int64(a.GetFileLength()), quoted
	case m.GetDocumentMessage() != nil:
		d := m.GetDocumentMessage()
		ctxInfo(d.GetContextInfo())
		return "document", d.GetCaption(), d.GetMimetype(), d.GetFileName(), int64(d.GetFileLength()), quoted
	case m.GetStickerMessage() != nil:
		s := m.GetStickerMessage()
		return "sticker", "", s.GetMimetype(), "", int64(s.GetFileLength()), ""
	case m.GetLocationMessage() != nil:
		l := m.GetLocationMessage()
		return "location", fmt.Sprintf("%s %.6f,%.6f", l.GetName(), l.GetDegreesLatitude(), l.GetDegreesLongitude()), "", "", 0, ""
	case m.GetContactMessage() != nil:
		return "contact", m.GetContactMessage().GetDisplayName(), "", "", 0, ""
	case m.GetPollCreationMessage() != nil:
		p := m.GetPollCreationMessage()
		var opts []string
		for _, o := range p.GetOptions() {
			opts = append(opts, o.GetOptionName())
		}
		return "poll", p.GetName() + " [" + strings.Join(opts, " | ") + "]", "", "", 0, ""
	case m.GetReactionMessage() != nil:
		r := m.GetReactionMessage()
		return "reaction", r.GetText(), "", "", 0, r.GetKey().GetID()
	}
	return "other", "[unsupported message type]", "", "", 0, ""
}

func isMedia(kind string) bool {
	switch kind {
	case "image", "video", "audio", "voice", "document", "sticker":
		return true
	}
	return false
}

// extractMessage turns a message event into a stored row. norm maps LID
// addresses to phone-number JIDs when it can. A second return of kind
// "revoke"/"edit" signals a change to an existing message instead.
func extractMessage(e *events.Message, norm func(types.JID) types.JID) (Msg, string, string) {
	if pm := e.RawMessage.GetProtocolMessage(); pm != nil {
		switch pm.GetType() {
		case waE2E.ProtocolMessage_REVOKE:
			return Msg{Chat: norm(e.Info.Chat).String(), ID: pm.GetKey().GetID()}, "revoke", ""
		case waE2E.ProtocolMessage_MESSAGE_EDIT:
			_, txt, _, _, _, _ := describe(pm.GetEditedMessage())
			return Msg{Chat: norm(e.Info.Chat).String(), ID: pm.GetKey().GetID()}, "edit", txt
		}
	}
	kind, text, mime, fname, size, quoted := describe(e.Message)
	m := Msg{
		Chat:       norm(e.Info.Chat).String(),
		ID:         e.Info.ID,
		Sender:     norm(e.Info.Sender).String(),
		SenderName: e.Info.PushName,
		TS:         e.Info.Timestamp.Unix(),
		FromMe:     e.Info.IsFromMe,
		Kind:       kind, Text: text, Mime: mime, Filename: fname, Size: size, QuotedID: quoted,
	}
	if isMedia(kind) {
		m.Raw, _ = proto.Marshal(e.Message)
	}
	return m, "", ""
}
