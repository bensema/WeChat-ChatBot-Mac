package main

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// Exercise the real exec boundary used by App supervision: the child must
// retain its PID, arguments, cwd and output pipes, and exec exactly once.
func TestFridaRuntimeReexec(t *testing.T) {
	if !needsFridaSignalCompatibility(runtime.GOOS, runtime.GOARCH) {
		t.Skip("Intel macOS compatibility path")
	}
	const marker = "ONEBOT_TEST_FRIDA_REEXEC"
	if os.Getenv(marker) == "1" {
		if err := ensureFridaRuntimeCompatibility(); err != nil {
			t.Fatal(err)
		}
		if _, changed := fridaSafeGODEBUG(os.Getenv("GODEBUG")); changed {
			t.Fatal("child did not receive a safe startup environment")
		}
		cwd, err := os.Getwd()
		if err != nil {
			t.Fatal(err)
		}
		fmt.Printf("child pid=%d cwd=%s\n", os.Getpid(), cwd)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestFridaRuntimeReexec$")
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	cmd.Dir = dir
	for _, env := range os.Environ() {
		if !strings.HasPrefix(env, "GODEBUG=") && !strings.HasPrefix(env, marker+"=") {
			cmd.Env = append(cmd.Env, env)
		}
	}
	cmd.Env = append(cmd.Env, "GODEBUG=gctrace=0,asyncpreemptoff=0", marker+"=1")
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("child failed: %v\n%s\n%s", err, &stdout, &stderr)
	}
	if want := fmt.Sprintf("child pid=%d cwd=%s\n", cmd.Process.Pid, cmd.Dir); !strings.Contains(stdout.String(), want) {
		t.Fatalf("PID/cwd/arguments/stdout were not preserved: %s", &stdout)
	}
	if count := strings.Count(stderr.String(), "Intel Frida 兼容模式"); count != 1 {
		t.Fatalf("expected exactly one exec via stderr pipe, got %d: %s", count, &stderr)
	}
}

func TestFridaSafeGODEBUG(t *testing.T) {
	for _, tc := range []struct {
		name, input, want string
		changed           bool
	}{
		{"empty", "", "asyncpreemptoff=1", true},
		{"preserve other options", "gctrace=1", "gctrace=1,asyncpreemptoff=1", true},
		{"override unsafe setting", "asyncpreemptoff=0,gctrace=1", "asyncpreemptoff=0,gctrace=1,asyncpreemptoff=1", true},
		{"already safe", "gctrace=1,asyncpreemptoff=1", "gctrace=1,asyncpreemptoff=1", false},
		{"last setting wins", "asyncpreemptoff=1,asyncpreemptoff=0", "asyncpreemptoff=1,asyncpreemptoff=0,asyncpreemptoff=1", true},
		{"no reexec loop", "asyncpreemptoff=0,asyncpreemptoff=1", "asyncpreemptoff=0,asyncpreemptoff=1", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, changed := fridaSafeGODEBUG(tc.input)
			if got != tc.want || changed != tc.changed {
				t.Fatalf("got (%q, %v), want (%q, %v)", got, changed, tc.want, tc.changed)
			}
			if _, changed := fridaSafeGODEBUG(got); changed {
				t.Fatal("compatibility setting must be idempotent")
			}
		})
	}
}

func TestFridaSignalCompatibilityHTTP(t *testing.T) {
	for _, tc := range []struct {
		os, arch, path string
		want           int
	}{
		{"darwin", "amd64", "/debug/pprof/profile", http.StatusServiceUnavailable},
		{"darwin", "arm64", "/debug/pprof/profile", http.StatusNoContent},
		{"linux", "amd64", "/debug/pprof/profile", http.StatusNoContent},
		{"darwin", "amd64", "/debug/pprof/goroutine", http.StatusNoContent},
		{"darwin", "amd64", "/send_private_msg", http.StatusNoContent},
		{"darwin", "amd64", "/ws", http.StatusNoContent},
	} {
		t.Run(tc.os+"/"+tc.arch+tc.path, func(t *testing.T) {
			next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusNoContent) })
			w := httptest.NewRecorder()
			fridaSafeHTTPHandlerForPlatform(next, tc.os, tc.arch).ServeHTTP(w, httptest.NewRequest("GET", tc.path, nil))
			if w.Code != tc.want {
				t.Fatalf("got %d, want %d", w.Code, tc.want)
			}
		})
	}
}
