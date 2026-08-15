package main

import (
	"testing"

	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"
)

func TestMessageContentPrefersText(t *testing.T) {
	text, media := messageContent(&waE2E.Message{Conversation: proto.String("  hello  ")})
	if text != "hello" || media != "" {
		t.Fatalf("got text=%q media=%q", text, media)
	}
}

func TestMessageContentKeepsMediaWithoutCaption(t *testing.T) {
	text, media := messageContent(&waE2E.Message{ImageMessage: &waE2E.ImageMessage{}})
	if text != "" || media != "image" {
		t.Fatalf("got text=%q media=%q", text, media)
	}
}

func TestConversationKind(t *testing.T) {
	if got := conversationKind(types.NewJID("123", types.GroupServer)); got != "group" {
		t.Fatalf("group JID mapped to %q", got)
	}
	if got := conversationKind(types.NewJID("15551234567", types.DefaultUserServer)); got != "direct" {
		t.Fatalf("user JID mapped to %q", got)
	}
}
