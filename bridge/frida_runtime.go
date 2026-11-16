package main

import (
	"fmt"
	"net/http"
	"os"
	"runtime"
	"strings"
	"syscall"
)

// The Intel Frida 17.8.0 archive embeds a second Go runtime (suntime,
// go1.24.3). SIGURG preemption can enter the host Go 1.25 signal handler on
// a suntime thread. Its incompatible g/m layout then faults in libcCall,
// retrying the same instruction and burning a core even while all bridge
// goroutines are idle. Disable signal-based preemption in BOTH runtimes.
// Setting GODEBUG with os.Setenv alone is insufficient: the embedded runtime
// has already read its startup environment. Exec preserves PID, arguments,
// working directory and stdout/stderr pipes used by the App supervisor.
func ensureFridaRuntimeCompatibility() error {
	if !needsFridaSignalCompatibility(runtime.GOOS, runtime.GOARCH) {
		return nil
	}
	current := os.Getenv("GODEBUG")
	safe, changed := fridaSafeGODEBUG(current)
	if !changed {
		return nil
	}
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	if err := os.Setenv("GODEBUG", safe); err != nil {
		return err
	}
	fmt.Fprintln(os.Stderr, "Intel Frida 兼容模式：关闭信号异步抢占，避免双 Go 运行时冲突")
	return syscall.Exec(executable, os.Args, os.Environ())
}

func needsFridaSignalCompatibility(goos, goarch string) bool {
	return goos == "darwin" && goarch == "amd64"
}

// GODEBUG uses the last occurrence of a setting. Preserve all other options
// and append the compatibility setting only when it is not already effective.
func fridaSafeGODEBUG(current string) (string, bool) {
	value := ""
	for _, setting := range strings.Split(current, ",") {
		if v, ok := strings.CutPrefix(setting, "asyncpreemptoff="); ok {
			value = v
		}
	}
	if value == "1" {
		return current, false
	}
	if current == "" {
		return "asyncpreemptoff=1", true
	}
	return current + ",asyncpreemptoff=1", true
}

// CPU pprof sends process-wide SIGPROF, which has the same cross-runtime TLS
// hazard as SIGURG. Keep the remaining debug endpoints available; use macOS
// sample for native CPU diagnosis on this platform instead.
func fridaSafeHTTPHandler(next http.Handler) http.Handler {
	return fridaSafeHTTPHandlerForPlatform(next, runtime.GOOS, runtime.GOARCH)
}

func fridaSafeHTTPHandlerForPlatform(next http.Handler, goos, goarch string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if needsFridaSignalCompatibility(goos, goarch) && r.URL.Path == "/debug/pprof/profile" {
			http.Error(w, "CPU profiling is disabled for Intel Frida's dual Go runtimes; use macOS sample instead", http.StatusServiceUnavailable)
			return
		}
		next.ServeHTTP(w, r)
	})
}
