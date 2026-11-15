package main

import (
	"context"
	"testing"
)

// Regression: a delivered x64 message returned HTTP 500 after waiting 15s for an
// ARM buf2resp event that its native completion never emits. It must also leave
// unrelated legacy response events available to their own waiter.
func TestX64TextDoesNotWaitForLegacyResponse(t *testing.T) {
	previousMode, previousResponses := x64NativeTextSend.Load(), buf2RespChan
	t.Cleanup(func() {
		x64NativeTextSend.Store(previousMode)
		buf2RespChan = previousResponses
	})
	x64NativeTextSend.Store(true)
	buf2RespChan = make(chan *Buf2RespData, 1)
	sentinel := &Buf2RespData{}
	buf2RespChan <- sentinel
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := waitForSendCompletion(ctx, 123, "text"); err != nil {
		t.Fatalf("submitted native text was reported as failed: %v", err)
	}
	select {
	case got := <-buf2RespChan:
		if got != sentinel {
			t.Fatal("legacy response was replaced")
		}
	default:
		t.Fatal("native text consumed an unrelated legacy response")
	}
}
