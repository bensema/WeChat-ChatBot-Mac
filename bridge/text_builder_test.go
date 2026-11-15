package main

import (
	"encoding/hex"
	"runtime"
	"testing"

	wxproto "github.com/yincongcyincong/weixin-macos/onebot/proto"
	"google.golang.org/protobuf/proto"
)

func TestTextProtoNativeClientIDWidth(t *testing.T) {
	encoded, err := BuildTextMsgProto("filehelper", "Intel bridge 自检", "wxid_example")
	if err != nil {
		t.Fatal(err)
	}
	data, err := hex.DecodeString(encoded)
	if err != nil {
		t.Fatal(err)
	}
	var message wxproto.WxSendTextMsg
	if err := proto.Unmarshal(data, &message); err != nil {
		t.Fatal(err)
	}
	if message.Body == nil || message.Body.Receiver.GetValue() != "filehelper" ||
		string(message.Body.Content) != "Intel bridge 自检" {
		t.Fatalf("text fields did not roundtrip: %v", &message)
	}
	id := message.Body.MsgId
	if id <= 0 || (runtime.GOARCH == "amd64" && id > 0x7fffffff) {
		t.Fatalf("clientmsgid %d does not fit native %s protobuf", id, runtime.GOARCH)
	}
}
