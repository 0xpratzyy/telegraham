package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	_ "github.com/mattn/go-sqlite3"
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waHistorySync"
	"go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

// This process deliberately exposes no send, receipt, presence, or mutation
// command. Pidgy's WhatsApp connection is a read-only linked-device reader.

type command struct {
	Command string `json:"command"`
}

type wireMessage struct {
	ID              string `json:"id"`
	ChatID          string `json:"chat_id"`
	SenderID        string `json:"sender_id,omitempty"`
	SenderName      string `json:"sender_name,omitempty"`
	SenderAvatarURL string `json:"sender_avatar_url,omitempty"`
	Timestamp       int64  `json:"timestamp"`
	Text            string `json:"text,omitempty"`
	MediaType       string `json:"media_type,omitempty"`
	FromMe          bool   `json:"from_me"`
}

type wireParticipant struct {
	ID        string   `json:"id"`
	Aliases   []string `json:"aliases,omitempty"`
	Name      string   `json:"name,omitempty"`
	AvatarURL string   `json:"avatar_url,omitempty"`
}

type wireConversation struct {
	ID           string            `json:"id"`
	Title        string            `json:"title"`
	Kind         string            `json:"kind"`
	UnreadCount  int               `json:"unread_count"`
	UpdatedAt    int64             `json:"updated_at"`
	AvatarURL    string            `json:"avatar_url,omitempty"`
	Participants []wireParticipant `json:"participants,omitempty"`
	Messages     []wireMessage     `json:"messages"`
}

type wireEvent struct {
	Type         string            `json:"type"`
	Code         string            `json:"code,omitempty"`
	Status       string            `json:"status,omitempty"`
	Message      string            `json:"message,omitempty"`
	AccountID    string            `json:"account_id,omitempty"`
	AccountName  string            `json:"account_name,omitempty"`
	Conversation *wireConversation `json:"conversation,omitempty"`
}

type bridge struct {
	ctx        context.Context
	client     *whatsmeow.Client
	out        *json.Encoder
	outMu      sync.Mutex
	connectMu  sync.Mutex
	qrCancel   context.CancelFunc
	metadataMu sync.RWMutex
	groups     map[string]wireConversation
}

func main() {
	storePath := flag.String("store", "", "path to the local WhatsApp session database")
	flag.Parse()
	if strings.TrimSpace(*storePath) == "" {
		fatalJSON("missing --store path")
	}
	if err := os.MkdirAll(filepath.Dir(*storePath), 0o700); err != nil {
		fatalJSON(fmt.Sprintf("create store directory: %v", err))
	}
	_ = os.Chmod(filepath.Dir(*storePath), 0o700)

	ctx := context.Background()
	container, err := sqlstore.New(ctx, "sqlite3", "file:"+*storePath+"?_foreign_keys=on&_busy_timeout=5000", nil)
	if err != nil {
		fatalJSON(fmt.Sprintf("open session store: %v", err))
	}
	defer container.Close()
	device, err := container.GetFirstDevice(ctx)
	if err != nil {
		fatalJSON(fmt.Sprintf("load session: %v", err))
	}
	client := whatsmeow.NewClient(device, nil)
	b := &bridge{ctx: ctx, client: client, out: json.NewEncoder(os.Stdout), groups: make(map[string]wireConversation)}
	client.AddEventHandler(b.handleEvent)
	b.emit(b.statusEvent("ready"))

	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		var cmd command
		if err := json.Unmarshal(scanner.Bytes(), &cmd); err != nil {
			b.emit(wireEvent{Type: "error", Message: "invalid command"})
			continue
		}
		switch cmd.Command {
		case "connect":
			go b.connect()
		case "status":
			b.emit(b.statusEvent("status"))
		case "logout":
			if b.qrCancel != nil {
				b.qrCancel()
			}
			if err := b.client.Logout(ctx); err != nil && !errors.Is(err, whatsmeow.ErrNotConnected) {
				b.emit(wireEvent{Type: "error", Message: "logout: " + err.Error()})
			} else {
				b.emit(wireEvent{Type: "logged_out", Status: "disconnected"})
			}
		case "shutdown":
			if b.qrCancel != nil {
				b.qrCancel()
			}
			b.client.Disconnect()
			return
		default:
			b.emit(wireEvent{Type: "error", Message: "unsupported command"})
		}
	}
	b.client.Disconnect()
}

func (b *bridge) connect() {
	b.connectMu.Lock()
	defer b.connectMu.Unlock()
	if b.client.IsConnected() {
		b.emit(b.statusEvent("connected"))
		return
	}
	if b.client.Store.ID == nil {
		qrCtx, cancel := context.WithCancel(b.ctx)
		b.qrCancel = cancel
		qrChannel, err := b.client.GetQRChannel(qrCtx)
		if err != nil {
			b.emit(wireEvent{Type: "error", Message: "start pairing: " + err.Error()})
			return
		}
		go func() {
			for item := range qrChannel {
				if item.Event == "code" {
					b.emit(wireEvent{Type: "qr", Code: item.Code, Status: "pairing"})
				} else {
					b.emit(wireEvent{Type: "pairing", Status: item.Event})
				}
			}
		}()
	}
	b.emit(wireEvent{Type: "connecting", Status: "connecting"})
	if err := b.client.Connect(); err != nil {
		b.emit(wireEvent{Type: "error", Message: "connect: " + err.Error()})
	}
}

func (b *bridge) handleEvent(raw any) {
	switch evt := raw.(type) {
	case *events.Connected:
		b.emit(b.statusEvent("connected"))
		go b.refreshGroupMetadata()
	case *events.Disconnected:
		b.emit(wireEvent{Type: "disconnected", Status: "disconnected"})
	case *events.LoggedOut:
		b.emit(wireEvent{Type: "logged_out", Status: "disconnected", Message: evt.Reason.String()})
	case *events.StreamReplaced:
		b.emit(wireEvent{Type: "error", Message: "WhatsApp replaced this linked-device session."})
	case *events.HistorySync:
		if evt.Data == nil {
			return
		}
		for _, conversation := range evt.Data.GetConversations() {
			converted := b.convertHistoryConversation(conversation)
			if len(converted.Messages) > 0 {
				b.emit(wireEvent{Type: "history", Conversation: &converted})
			}
		}
	case *events.Message:
		if evt.Info.Chat.ToNonAD() == types.StatusBroadcastJID {
			return
		}
		message := b.liveMessage(evt)
		if message.Text == "" && message.MediaType == "" {
			return
		}
		title := b.resolveTitle(evt.Info.Chat, evt.Info.PushName)
		conversation := wireConversation{
			ID: evt.Info.Chat.ToNonAD().String(), Title: title,
			Kind: conversationKind(evt.Info.Chat), UpdatedAt: message.Timestamp,
			Messages: []wireMessage{message},
		}
		b.applyCachedGroupMetadata(&conversation)
		b.emit(wireEvent{Type: "message", Conversation: &conversation})
	}
}

func (b *bridge) convertHistoryConversation(conversation *waHistorySync.Conversation) wireConversation {
	chatID := conversation.GetID()
	if chatID == types.StatusBroadcastJID.String() {
		return wireConversation{ID: chatID}
	}
	jid, _ := types.ParseJID(chatID)
	messages := make([]wireMessage, 0, len(conversation.GetMessages()))
	latestPushName := ""
	for _, item := range conversation.GetMessages() {
		if item == nil || item.GetMessage() == nil {
			continue
		}
		message := b.historyMessage(chatID, item.GetMessage())
		if message.Text == "" && message.MediaType == "" {
			continue
		}
		if message.SenderName != "" {
			latestPushName = message.SenderName
		}
		messages = append(messages, message)
	}
	title := firstNonEmpty(conversation.GetName(), conversation.GetDisplayName(), b.resolveTitle(jid, latestPushName))
	updatedAt := int64(conversation.GetLastMsgTimestamp())
	if updatedAt == 0 && len(messages) > 0 {
		updatedAt = messages[len(messages)-1].Timestamp
	}
	result := wireConversation{
		ID: chatID, Title: title, Kind: conversationKind(jid),
		UnreadCount: int(conversation.GetUnreadCount()), UpdatedAt: updatedAt, Messages: messages,
	}
	b.applyCachedGroupMetadata(&result)
	return result
}

func (b *bridge) historyMessage(chatID string, info *waWeb.WebMessageInfo) wireMessage {
	key := info.GetKey()
	message := info.GetMessage()
	senderID := key.GetParticipant()
	if senderID == "" {
		senderID = key.GetRemoteJID()
	}
	text, mediaType := messageContent(message)
	name := info.GetPushName()
	if senderJID, err := types.ParseJID(senderID); err == nil {
		name = b.resolveContactName(senderJID, name)
	}
	return wireMessage{
		ID: key.GetID(), ChatID: chatID, SenderID: senderID,
		SenderName: name, Timestamp: int64(info.GetMessageTimestamp()),
		Text: text, MediaType: mediaType, FromMe: key.GetFromMe(),
	}
}

func (b *bridge) liveMessage(evt *events.Message) wireMessage {
	text, mediaType := messageContent(evt.Message)
	return wireMessage{
		ID: string(evt.Info.ID), ChatID: evt.Info.Chat.ToNonAD().String(),
		SenderID: evt.Info.Sender.ToNonAD().String(), SenderName: b.resolveContactName(evt.Info.Sender, evt.Info.PushName),
		Timestamp: evt.Info.Timestamp.Unix(), Text: text, MediaType: mediaType,
		FromMe: evt.Info.IsFromMe,
	}
}

func messageContent(message *waE2E.Message) (string, string) {
	if message == nil {
		return "", ""
	}
	if text := strings.TrimSpace(message.GetConversation()); text != "" {
		return text, ""
	}
	if extended := message.GetExtendedTextMessage(); extended != nil {
		return strings.TrimSpace(extended.GetText()), ""
	}
	if image := message.GetImageMessage(); image != nil {
		return strings.TrimSpace(image.GetCaption()), "image"
	}
	if video := message.GetVideoMessage(); video != nil {
		return strings.TrimSpace(video.GetCaption()), "video"
	}
	if document := message.GetDocumentMessage(); document != nil {
		return strings.TrimSpace(document.GetCaption()), "document"
	}
	if message.GetAudioMessage() != nil {
		return "", "audio"
	}
	if message.GetStickerMessage() != nil {
		return "", "sticker"
	}
	return "", ""
}

func (b *bridge) resolveTitle(jid types.JID, pushName string) string {
	if jid.Server == types.GroupServer {
		b.metadataMu.RLock()
		group, ok := b.groups[jid.ToNonAD().String()]
		b.metadataMu.RUnlock()
		if ok && strings.TrimSpace(group.Title) != "" {
			return group.Title
		}
	}
	if name := b.resolveContactName(jid, pushName); name != "" {
		return name
	}
	if pushName = strings.TrimSpace(pushName); pushName != "" {
		return pushName
	}
	if jid.User != "" {
		return jid.User
	}
	return "WhatsApp chat"
}

func (b *bridge) resolveContactName(jid types.JID, pushName string) string {
	candidates := []types.JID{jid.ToNonAD()}
	if jid.Server == types.HiddenUserServer && b.client.Store.LIDs != nil {
		if pn, err := b.client.Store.LIDs.GetPNForLID(b.ctx, jid.ToNonAD()); err == nil && !pn.IsEmpty() {
			candidates = append(candidates, pn.ToNonAD())
		}
	}
	if b.client.Store.Contacts != nil {
		for _, candidate := range candidates {
			if info, err := b.client.Store.Contacts.GetContact(b.ctx, candidate); err == nil {
				if name := firstNonEmpty(info.FullName, info.FirstName, info.PushName, info.BusinessName); name != "" {
					return name
				}
			}
		}
	}
	if name := strings.TrimSpace(pushName); name != "" {
		return name
	}
	if jid.Server == types.DefaultUserServer && jid.User != "" {
		return "+" + jid.User
	}
	return ""
}

func (b *bridge) refreshGroupMetadata() {
	groups, err := b.client.GetJoinedGroups(b.ctx)
	if err != nil {
		return
	}
	for _, group := range groups {
		if group == nil {
			continue
		}
		conversation := wireConversation{
			ID: group.JID.ToNonAD().String(), Title: strings.TrimSpace(group.Name),
			Kind: "group", Messages: []wireMessage{},
		}
		if picture, err := b.client.GetProfilePictureInfo(b.ctx, group.JID, &whatsmeow.GetProfilePictureParams{Preview: true}); err == nil && picture != nil {
			conversation.AvatarURL = picture.URL
		}
		for _, participant := range group.Participants {
			primary := participant.JID.ToNonAD()
			aliases := uniqueStrings(primary.String(), participant.PhoneNumber.ToNonAD().String(), participant.LID.ToNonAD().String())
			name := b.resolveContactName(primary, participant.DisplayName)
			avatarURL := ""
			if picture, err := b.client.GetProfilePictureInfo(b.ctx, primary, &whatsmeow.GetProfilePictureParams{Preview: true, CommonGID: group.JID}); err == nil && picture != nil {
				avatarURL = picture.URL
			}
			conversation.Participants = append(conversation.Participants, wireParticipant{
				ID: primary.String(), Aliases: aliases, Name: name, AvatarURL: avatarURL,
			})
		}
		b.metadataMu.Lock()
		b.groups[conversation.ID] = conversation
		b.metadataMu.Unlock()
		b.emit(wireEvent{Type: "metadata", Conversation: &conversation})
	}
}

func (b *bridge) applyCachedGroupMetadata(conversation *wireConversation) {
	if conversation == nil || conversation.Kind != "group" {
		return
	}
	b.metadataMu.RLock()
	metadata, ok := b.groups[conversation.ID]
	b.metadataMu.RUnlock()
	if !ok {
		return
	}
	if metadata.Title != "" {
		conversation.Title = metadata.Title
	}
	conversation.AvatarURL = metadata.AvatarURL
	conversation.Participants = metadata.Participants
}

func uniqueStrings(values ...string) []string {
	seen := make(map[string]bool)
	result := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" || seen[value] {
			continue
		}
		seen[value] = true
		result = append(result, value)
	}
	return result
}

func conversationKind(jid types.JID) string {
	if jid.Server == types.GroupServer || jid.IsBroadcastList() {
		return "group"
	}
	return "direct"
}

func (b *bridge) statusEvent(eventType string) wireEvent {
	event := wireEvent{Type: eventType}
	if b.client.IsConnected() {
		event.Status = "connected"
	} else if b.client.Store.ID != nil {
		event.Status = "disconnected"
	} else {
		event.Status = "unpaired"
	}
	if b.client.Store.ID != nil {
		event.AccountID = b.client.Store.ID.ToNonAD().String()
		event.AccountName = firstNonEmpty(b.client.Store.PushName, b.client.Store.BusinessName, b.client.Store.ID.User)
	}
	return event
}

func (b *bridge) emit(event wireEvent) {
	if event.AccountID == "" && b.client.Store.ID != nil {
		event.AccountID = b.client.Store.ID.ToNonAD().String()
		event.AccountName = firstNonEmpty(b.client.Store.PushName, b.client.Store.BusinessName, b.client.Store.ID.User)
	}
	b.outMu.Lock()
	defer b.outMu.Unlock()
	_ = b.out.Encode(event)
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value = strings.TrimSpace(value); value != "" {
			return value
		}
	}
	return ""
}

func fatalJSON(message string) {
	_ = json.NewEncoder(os.Stdout).Encode(wireEvent{Type: "error", Message: message})
	time.Sleep(20 * time.Millisecond)
	os.Exit(1)
}
