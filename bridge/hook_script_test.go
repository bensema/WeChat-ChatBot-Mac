package main

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestRenderBundledX64HookIncludesContactExports(t *testing.T) {
	var conf map[string]interface{}
	configData, err := os.ReadFile("../hook/versions/4_1_15_35_x86_64.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(configData, &conf); err != nil {
		t.Fatal(err)
	}
	base, err := os.ReadFile("../hook/script-x86_64.js")
	if err != nil {
		t.Fatal(err)
	}
	contact, err := os.ReadFile("../hook/contact-directory-x64.js")
	if err != nil {
		t.Fatal(err)
	}
	code, err := renderHookScript(conf, base, contact)
	if err != nil {
		t.Fatal(err)
	}
	module := strings.Index(code, "function getContactDirectory(dbStoragePath)")
	exports := strings.Index(code, "rpc.exports =")
	if module < 0 || exports < 0 || module >= exports {
		t.Fatal("rendered x64 contact implementation must precede the RPC export table")
	}
	for _, name := range []string{"getContactDirectory:getContactDirectory", "setDbKeys:setDbKeys", "getDbKeyStatus:getDbKeyStatus"} {
		if !strings.Contains(code, name) {
			t.Fatalf("rendered x64 hook lacks RPC export %q", name)
		}
	}
}

func TestRenderHookScriptLeavesArmScriptUnchanged(t *testing.T) {
	conf := map[string]interface{}{"arch": "arm64", "contactDirectory": "true"}
	code, err := renderHookScript(conf, []byte("arm={{.contactDirectory}}"), []byte("x64-only"))
	if err != nil {
		t.Fatal(err)
	}
	if code != "arm=true" {
		t.Fatalf("unexpected ARM script: %q", code)
	}
}
