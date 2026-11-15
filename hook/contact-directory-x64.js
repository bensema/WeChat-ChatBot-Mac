var HOOK_DEBUG = false;
var contactDirectoryEnabled = "{{.contactDirectory}}" === "true";
var dbKeyCaptureEnabled = contactDirectoryEnabled;
var CONTACT_PAGE_SIZE = 4096;
var CONTACT_RESERVE = 80;
var CONTACT_CT_LEN = CONTACT_PAGE_SIZE - CONTACT_RESERVE; // 4016
var CONTACT_SALT_LEN = 16;
var CONTACT_IV_LEN = 16;
var CONTACT_MAX_DB_BYTES = 64 * 1024 * 1024;
var CONTACT_MAX_CANDIDATES = 128;
var CONTACT_MAX_ENTRIES = 20000;
var CONTACT_MAX_GROUP_MEMBERS = 2000;
var CONTACT_SQLITE_HDR = [0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66, 0x6f, 0x72, 0x6d, 0x61, 0x74, 0x20, 0x33, 0x00];
var contactState = {
    installed: false,
    ccCrypt: null,
    pbkdf2: null,
    unlinkFn: null,
    inCrypto: false,
    keysBySalt: {},      // saltHex -> keyHex（已用页 1 校验）
    providedKeys: {},    // saltHex -> keyHex（bridge 从缓存回灌）
    candidates: [],      // 未校验的 keyHex（AES 调用 / PBKDF2 输出）
    candidateSet: {},
    passphraseHex: null,
    derivedBySalt: {},   // saltHex -> keyHex（PBKDF2 输出，已校验前）
    lastError: null
};

function contactDebug() {
    if (!HOOK_DEBUG) return;
    try {
        var parts = ["[contact]"];
        for (var i = 0; i < arguments.length; i++) parts.push(arguments[i]);
        console.log(parts.join(" "));
    } catch (e) { /* 日志失败不影响 Hook */ }
}

function contactFindExport(name) {
    try {
        if (typeof Module.findGlobalExportByName === "function") {
            var p = Module.findGlobalExportByName(name);
            if (p) return p;
        }
    } catch (e) { /* 旧版 Frida 没有该 API */ }
    try {
        if (typeof Module.findExportByName === "function") {
            var q = Module.findExportByName(null, name);
            if (q) return q;
        }
    } catch (e) { }
    try {
        var m = Process.findModuleByName("libcommonCrypto.dylib");
        if (m && typeof m.findExportByName === "function") {
            var r = m.findExportByName(name);
            if (r) return r;
        }
    } catch (e) { }
    return null;
}

function contactHexToBytes(hex) {
    var out = [];
    for (var i = 0; i + 1 < hex.length; i += 2) out.push(parseInt(hex.substr(i, 2), 16));
    return out;
}

function contactBytesToHex(bytes) {
    var s = "";
    for (var i = 0; i < bytes.length; i++) s += ("0" + bytes[i].toString(16)).slice(-2);
    return s;
}

function contactPtrHex(p, len) {
    if (!p || p.isNull() || len <= 0) return null;
    try {
        return contactBytesToHex(new Uint8Array(p.readByteArray(len)));
    } catch (e) {
        return null;
    }
}

function contactU32BE(u8, off) {
    return ((u8[off] << 24) | (u8[off + 1] << 16) | (u8[off + 2] << 8) | u8[off + 3]) >>> 0;
}

function contactU32LE(u8, off) {
    return (u8[off] | (u8[off + 1] << 8) | (u8[off + 2] << 16) | (u8[off + 3] << 24)) >>> 0;
}

// 候选 key 去重；日志里绝不打印 key 本身。
function contactNoteCandidate(hex, source) {
    try {
        if (!hex || hex.length !== 64) return;
        if (contactState.candidateSet[hex]) return;
        if (contactState.candidates.length >= CONTACT_MAX_CANDIDATES) return;
        contactState.candidateSet[hex] = source || "aes";
        contactState.candidates.push(hex);
        contactDebug("新 key 候选 source=" + (source || "aes") + " total=" + contactState.candidates.length);
    } catch (e) {
        contactState.lastError = String(e);
    }
}

function contactCaptureAesKey(keyPtr, keyLen, source) {
    try {
        if (!dbKeyCaptureEnabled || contactState.inCrypto) return;
        if (keyLen !== 32) return;
        contactNoteCandidate(contactPtrHex(keyPtr, 32), source);
    } catch (e) {
        contactState.lastError = String(e);
    }
}

function contactSetupHooks() {
    if (contactState.installed) return;
    if (!dbKeyCaptureEnabled) {
        console.log("[contact] DB key 捕获未启用（contactDirectory/snsDbRead/snsProbe 均为 false）");
        return;
    }
    try {
        if (typeof File === "undefined" || typeof SqliteDatabase === "undefined") {
            console.log("[!] [contact] 当前 Frida 运行时不支持 File/SqliteDatabase，通讯录读取关闭");
            return;
        }
        var cc = contactFindExport("CCCrypt");
        if (!cc) {
            console.log("[!] [contact] 找不到系统 CCCrypt，通讯录读取关闭");
            return;
        }
        contactState.ccCrypt = new NativeFunction(cc, "int",
            ["uint32", "uint32", "uint32", "pointer", "ulong", "pointer", "pointer", "ulong", "pointer", "ulong", "pointer"]);
        var pbkdf2 = contactFindExport("CCKeyDerivationPBKDF");
        if (pbkdf2) {
            contactState.pbkdf2 = new NativeFunction(pbkdf2, "int",
                ["uint32", "pointer", "ulong", "pointer", "ulong", "uint32", "uint32", "pointer", "ulong"]);
        }
        var create = contactFindExport("CCCryptorCreate");
        var createMode = contactFindExport("CCCryptorCreateWithMode");
        var crypt = contactFindExport("CCCrypt");
        if (create) {
            Interceptor.attach(create, {
                onEnter: function (args) {
                    try {
                        var alg = args[1].toInt32();
                        if (alg !== 0) return; // kCCAlgorithmAES
                        contactCaptureAesKey(args[3], args[4].toInt32(), "create");
                    } catch (e) { contactState.lastError = String(e); }
                }
            });
        }
        if (createMode) {
            Interceptor.attach(createMode, {
                onEnter: function (args) {
                    try {
                        if (args[2].toInt32() !== 0) return; // kCCAlgorithmAES
                        contactCaptureAesKey(args[5], args[6].toInt32(), "createMode");
                    } catch (e) { contactState.lastError = String(e); }
                }
            });
        }
        if (crypt) {
            Interceptor.attach(crypt, {
                onEnter: function (args) {
                    try {
                        if (args[1].toInt32() !== 0) return; // kCCAlgorithmAES
                        contactCaptureAesKey(args[3], args[4].toInt32(), "crypt");
                    } catch (e) { contactState.lastError = String(e); }
                }
            });
        }
        if (pbkdf2) {
            // 登录期：rounds=256000 输出 32 字节 → passphrase 与 enc_key。
            Interceptor.attach(pbkdf2, {
                onEnter: function (args) {
                    try {
                        if (contactState.inCrypto) return;
                        if (args[6].toInt32() !== 256000) return;
                        if (args[2].toInt32() !== 32 || args[8].toInt32() !== 32) return;
                        var pw = contactPtrHex(args[1], 32);
                        var out = contactPtrHex(args[7], 32);
                        var salt = contactPtrHex(args[3], 16);
                        if (pw) contactState.passphraseHex = pw;
                        if (out) contactNoteCandidate(out, "pbkdf2");
                        if (salt && out) contactState.derivedBySalt[salt] = out;
                        contactDebug("捕获 PBKDF2 passphrase/enc_key salt=" + (salt ? salt.substring(0, 8) : "?"));
                    } catch (e) { contactState.lastError = String(e); }
                }
            });
        }
        contactState.installed = true;
        console.log("[+] [contact] 通讯录 Hook 已安装（AES key + PBKDF2 passphrase 捕获）");
    } catch (e) {
        console.log("[!] [contact] Hook 安装失败: " + e);
    }
}

function contactAesDecrypt(keyBuf, ctBytes, ivBytes) {
    try {
        var inBuf = Memory.alloc(ctBytes.length);
        inBuf.writeByteArray(ctBytes);
        var ivBuf = Memory.alloc(16);
        ivBuf.writeByteArray(ivBytes);
        var outBuf = Memory.alloc(ctBytes.length);
        var moved = Memory.alloc(8);
        moved.writeU64(0);
        contactState.inCrypto = true;
        var rc;
        try {
            rc = contactState.ccCrypt(1, 0, 0, keyBuf, 32, ivBuf, inBuf, ctBytes.length, outBuf, ctBytes.length, moved);
        } finally {
            contactState.inCrypto = false;
        }
        if (rc !== 0) return null;
        return new Uint8Array(outBuf.readByteArray(ctBytes.length));
    } catch (e) {
        contactState.lastError = String(e);
        return null;
    }
}

function contactPage1MatchesKey(keyHex, page1) {
    try {
        var keyBuf = Memory.alloc(32);
        keyBuf.writeByteArray(contactHexToBytes(keyHex));
        var plain = contactAesDecrypt(keyBuf, page1.subarray(16, CONTACT_CT_LEN), page1.subarray(CONTACT_CT_LEN, CONTACT_CT_LEN + 16));
        if (!plain) return false;
        // 页 1 的明文中 [0,16) 是 "SQLite format 3\0"，但 SQLCipher 只加密
        // [16,4016)，所以解密输出的 plain[0] 对应明文第 16 字节：页大小高位、
        // 保留区大小等固定字段，用来校验 key 是否正确。
        return plain[0] === 0x10 && plain[1] === 0x00 && plain[4] === 0x50;
    } catch (e) {
        contactState.lastError = String(e);
        return false;
    }
}

function contactDeriveKeyFromPassphrase(passphraseHex, saltHex) {
    if (!contactState.pbkdf2) return null;
    try {
        var pw = Memory.alloc(32);
        pw.writeByteArray(contactHexToBytes(passphraseHex));
        var salt = Memory.alloc(16);
        salt.writeByteArray(contactHexToBytes(saltHex));
        var out = Memory.alloc(32);
        contactState.inCrypto = true;
        var rc;
        try {
            // CommonCrypto: kCCPBKDF2=2, kCCPRFHmacAlgSHA512=5
            rc = contactState.pbkdf2(2, pw, 32, salt, 16, 5, 256000, out, 32);
        } finally {
            contactState.inCrypto = false;
        }
        if (rc !== 0) return null;
        return contactBytesToHex(new Uint8Array(out.readByteArray(32)));
    } catch (e) {
        contactState.lastError = String(e);
        return null;
    }
}

// 用页 1 校验并缓存某个 DB 的 key。
function contactResolveKeyByPage1(page1) {
    try {
        if (!page1 || page1.length < CONTACT_PAGE_SIZE) return null;
        var salt = contactBytesToHex(page1.subarray(0, 16));
        var cached = contactState.keysBySalt[salt];
        if (cached && contactPage1MatchesKey(cached, page1)) return { salt: salt, keyHex: cached, source: "cached" };
        var provided = contactState.providedKeys[salt];
        if (provided && contactPage1MatchesKey(provided, page1)) {
            contactState.keysBySalt[salt] = provided;
            return { salt: salt, keyHex: provided, source: "provided" };
        }
        var derived = contactState.derivedBySalt[salt];
        if (derived && contactPage1MatchesKey(derived, page1)) {
            contactState.keysBySalt[salt] = derived;
            return { salt: salt, keyHex: derived, source: "derived" };
        }
        for (var i = 0; i < contactState.candidates.length; i++) {
            var candidate = contactState.candidates[i];
            if (contactPage1MatchesKey(candidate, page1)) {
                contactState.keysBySalt[salt] = candidate;
                contactDebug("页 1 校验通过 salt=" + salt.substring(0, 8) + " source=candidate");
                return { salt: salt, keyHex: candidate, source: "candidate" };
            }
        }
        if (contactState.passphraseHex) {
            var k = contactDeriveKeyFromPassphrase(contactState.passphraseHex, salt);
            if (k && contactPage1MatchesKey(k, page1)) {
                contactState.keysBySalt[salt] = k;
                contactDebug("页 1 校验通过 salt=" + salt.substring(0, 8) + " source=passphrase");
                return { salt: salt, keyHex: k, source: "passphrase" };
            }
        }
        return null;
    } catch (e) {
        contactState.lastError = String(e);
        return null;
    }
}

function contactDecryptPageAt(u8, offset, pgno, keyBuf) {
    try {
        var ctOff, ctLen, ivOff;
        if (pgno === 1) {
            ctOff = offset + CONTACT_SALT_LEN;
            ctLen = CONTACT_CT_LEN - CONTACT_SALT_LEN; // 4000
            ivOff = offset + CONTACT_CT_LEN;
        } else {
            ctOff = offset;
            ctLen = CONTACT_CT_LEN; // 4016
            ivOff = offset + CONTACT_CT_LEN;
        }
        var ct = u8.subarray(ctOff, ctOff + ctLen);
        var iv = u8.subarray(ivOff, ivOff + 16);
        var plain = contactAesDecrypt(keyBuf, ct, iv);
        if (!plain) return null;
        var page = new Uint8Array(CONTACT_PAGE_SIZE);
        page.set(plain, pgno === 1 ? CONTACT_SALT_LEN : 0);
        if (pgno === 1) {
            for (var i = 0; i < 16; i++) page[i] = CONTACT_SQLITE_HDR[i];
        }
        return page;
    } catch (e) {
        contactState.lastError = String(e);
        return null;
    }
}

// SQLite WAL 校验和：8 字节一组，按本机字节序读 u32；
// magic 低 bit=1 表示异序（byte-swapped），与 sqlite walChecksumBytes 一致。
function contactWalChecksum(u8, offset, len, s1, s2, bigEndCksum) {
    var end = offset + len;
    for (var i = offset; i < end; i += 8) {
        var w0 = bigEndCksum ? contactU32BE(u8, i) : contactU32LE(u8, i);
        var w1 = bigEndCksum ? contactU32BE(u8, i + 4) : contactU32LE(u8, i + 4);
        s1 = (s1 + w0 + s2) >>> 0;
        s2 = (s2 + w1 + s1) >>> 0;
    }
    return [s1, s2];
}

// 把 WAL 中「当前代」已提交帧合并进 pages。旧代帧（salt 不匹配/校验和断链）忽略。
function contactApplyWal(dbPath, keyBuf, pages) {
    var wal;
    try {
        wal = new Uint8Array(File.readAllBytes(dbPath + "-wal"));
    } catch (e) {
        return 0; // 没有 WAL 或不可读：主库已是最新
    }
    if (wal.length < 32 + 24 + CONTACT_PAGE_SIZE) return 0;
    try {
        var magic = contactU32BE(wal, 0);
        if (contactU32BE(wal, 8) !== CONTACT_PAGE_SIZE) return 0;
        if (magic !== 0x377f0682 && magic !== 0x377f0683) return 0;
        var bigEndCksum = (magic & 1) === 1;
        var hs1 = contactU32BE(wal, 16), hs2 = contactU32BE(wal, 20);
        var hc1 = contactU32BE(wal, 24), hc2 = contactU32BE(wal, 28);
        var headerCk = contactWalChecksum(wal, 0, 24, 0, 0, bigEndCksum);
        if (headerCk[0] !== hc1 || headerCk[1] !== hc2) {
            contactDebug("WAL 头校验失败，忽略 WAL");
            return 0;
        }
        var frames = [];
        var cs1 = hc1, cs2 = hc2;
        var off = 32;
        var lastCommit = -1;
        while (off + 24 + CONTACT_PAGE_SIZE <= wal.length) {
            var pgno = contactU32BE(wal, off);
            var ntrunc = contactU32BE(wal, off + 4);
            var fs1 = contactU32BE(wal, off + 8);
            var fs2 = contactU32BE(wal, off + 12);
            var fc1 = contactU32BE(wal, off + 16);
            var fc2 = contactU32BE(wal, off + 20);
            if (fs1 !== hs1 || fs2 !== hs2) break; // 上一代残留帧
            var ck = contactWalChecksum(wal, off, 16, cs1, cs2, bigEndCksum);
            ck = contactWalChecksum(wal, off + 24, CONTACT_PAGE_SIZE, ck[0], ck[1], bigEndCksum);
            if (ck[0] !== fc1 || ck[1] !== fc2) break;
            frames.push({ pgno: pgno, offset: off + 24 });
            if (ntrunc !== 0) lastCommit = frames.length - 1;
            cs1 = fc1;
            cs2 = fc2;
            off += 24 + CONTACT_PAGE_SIZE;
        }
        if (lastCommit < 0) return 0;
        var applied = 0;
        for (var i = 0; i <= lastCommit; i++) {
            var f = frames[i];
            if (f.pgno < 1 || f.pgno > 200000) continue;
            var plain = contactDecryptPageAt(wal, f.offset, f.pgno, keyBuf);
            if (plain) {
                pages[f.pgno] = plain;
                applied++;
            }
        }
        if (applied > 0) contactDebug("WAL 已合并帧 " + applied + "/" + frames.length);
        return applied;
    } catch (e) {
        contactState.lastError = String(e);
        return 0;
    }
}

function contactDecryptDatabase(dbBytes, keyHex, dbPath) {
    try {
        var keyBuf = Memory.alloc(32);
        keyBuf.writeByteArray(contactHexToBytes(keyHex));
        var pageCount = Math.floor(dbBytes.length / CONTACT_PAGE_SIZE);
        if (pageCount <= 0) return null;
        var pages = new Array(pageCount + 1);
        var bad = 0;
        for (var p = 1; p <= pageCount; p++) {
            var page = contactDecryptPageAt(dbBytes, (p - 1) * CONTACT_PAGE_SIZE, p, keyBuf);
            if (!page) bad++;
            pages[p] = page;
        }
        if (!pages[1]) return null;
        var walApplied = contactApplyWal(dbPath, keyBuf, pages);
        var total = 0;
        for (var k in pages) {
            if (pages[k] && parseInt(k, 10) > total) total = parseInt(k, 10);
        }
        var out = new Uint8Array(total * CONTACT_PAGE_SIZE);
        for (var i = 1; i <= total; i++) {
            if (pages[i]) out.set(pages[i], (i - 1) * CONTACT_PAGE_SIZE);
        }
        return { bytes: out, pages: total, bad: bad, walApplied: walApplied };
    } catch (e) {
        contactState.lastError = String(e);
        return null;
    }
}

function contactTempDir(dbStoragePath) {
    var idx = dbStoragePath.indexOf("/Documents/");
    if (idx > 0) return dbStoragePath.substring(0, idx) + "/tmp";
    return null;
}

function contactWriteTempDb(bytes, dbStoragePath, tag) {
    try {
        var dir = contactTempDir(dbStoragePath);
        if (!dir) return null;
        var prefix = tag ? String(tag) : "contact";
        var path = dir + "/wechatai-" + prefix + "-" + Process.id + "-" + Date.now().toString(36) + ".db";
        File.writeAllBytes(path, bytes.buffer);
        return path;
    } catch (e) {
        contactState.lastError = String(e);
        return null;
    }
}

function contactUnlink(path) {
    try {
        if (!path) return;
        if (!contactState.unlinkFn) {
            var p = contactFindExport("unlink");
            if (p) contactState.unlinkFn = new NativeFunction(p, "int", ["pointer"]);
        }
        if (contactState.unlinkFn) {
            contactState.unlinkFn(Memory.allocUtf8String(path));
        }
    } catch (e) { /* 清理失败不影响结果 */ }
}

function contactCleanupTempDb(path) {
    if (!path) return;
    contactUnlink(path);
    contactUnlink(path + "-wal");
    contactUnlink(path + "-shm");
    contactUnlink(path + "-journal");
}
function contactUtf8(u8) {
    var out = "";
    var i = 0;
    while (i < u8.length) {
        var c = u8[i++];
        if (c < 0x80) {
            out += String.fromCharCode(c);
        } else if (c >= 0xc0 && c < 0xe0) {
            if (i >= u8.length) break;
            out += String.fromCharCode(((c & 0x1f) << 6) | (u8[i++] & 0x3f));
        } else if (c >= 0xe0 && c < 0xf0) {
            if (i + 1 >= u8.length) break;
            out += String.fromCharCode(((c & 0x0f) << 12) | ((u8[i++] & 0x3f) << 6) | (u8[i++] & 0x3f));
        } else if (c >= 0xf0) {
            if (i + 2 >= u8.length) break;
            var cp = (((c & 0x07) << 18) | ((u8[i++] & 0x3f) << 12) |
                ((u8[i++] & 0x3f) << 6) | (u8[i++] & 0x3f)) - 0x10000;
            out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
        }
    }
    return out;
}

function contactParseGroupMembers(hex) {
    var members = {};
    if (!hex || hex.length < 6 || hex.length % 2 !== 0) return members;
    var bytes;
    try {
        bytes = new Uint8Array(contactHexToBytes(hex));
    } catch (e) {
        return members;
    }
    var count = 0;
    function readVarint(buf, pos) {
        var value = 0, shift = 0, b;
        do {
            if (pos >= buf.length || shift > 49) throw new Error("varint");
            b = buf[pos++];
            value += (b & 0x7f) * Math.pow(2, shift);
            shift += 7;
        } while (b & 0x80);
        return [value, pos];
    }
    function readBytes(buf, pos) {
        var r = readVarint(buf, pos);
        var len = r[0];
        pos = r[1];
        if (len < 0 || pos + len > buf.length) throw new Error("len");
        return [buf.subarray(pos, pos + len), pos + len];
    }
    try {
        var pos = 0;
        while (pos < bytes.length && count < CONTACT_MAX_GROUP_MEMBERS) {
            var tr = readVarint(bytes, pos);
            var key = tr[0];
            pos = tr[1];
            var field = Math.floor(key / 8), wire = key % 8;
            if (field !== 1 || wire !== 2) break; // 成员列表之后是房间级字段，不再需要
            var sr = readBytes(bytes, pos);
            var msg = sr[0];
            pos = sr[1];
            var mp = 0, username = "", display = "";
            while (mp < msg.length) {
                var mr = readVarint(msg, mp);
                var mk = mr[0];
                mp = mr[1];
                var mf = Math.floor(mk / 8), mw = mk % 8;
                if (mw === 2) {
                    var vr = readBytes(msg, mp);
                    var val = vr[0];
                    mp = vr[1];
                    if (mf === 1) username = contactUtf8(val);
                    else if (mf === 2) display = contactUtf8(val);
                } else if (mw === 0) {
                    var skip = readVarint(msg, mp);
                    mp = skip[1];
                } else if (mw === 5) {
                    mp += 4;
                } else if (mw === 1) {
                    mp += 8;
                } else {
                    break;
                }
                if (username.length > 128) break;
            }
            if (username) {
                // 未设置群昵称时 display 留空：调用方（bridge）回退到通讯录显示名，
                // 不能把 wxid 当成群昵称写进 sender.nickname。
                members[username] = {
                    display: display,
                    nickname: display,
                    remark: "",
                    alias: ""
                };
                count++;
            }
        }
    } catch (e) {
        contactDebug("群昵称解析失败: " + e);
    }
    return members;
}

function contactQueryDirectory(dbPath) {
    var users = {};
    var groups = {};
    var count = 0;
    var db = null;
    try {
        db = SqliteDatabase.open(dbPath);
        var stmt = db.prepare("SELECT username, nick_name, remark, alias, delete_flag FROM contact;");
        var row = stmt.step();
        while (row && count < CONTACT_MAX_ENTRIES) {
            var username = row[0] ? String(row[0]) : "";
            var deleted = row[4] ? Number(row[4]) : 0;
            if (username && !deleted) {
                var nick = row[1] ? String(row[1]) : "";
                var remark = row[2] ? String(row[2]) : "";
                var alias = row[3] ? String(row[3]) : "";
                var entry = {
                    display: remark || nick || alias || username,
                    nickname: nick,
                    remark: remark,
                    alias: alias
                };
                if (username.indexOf("@chatroom") >= 0) groups[username] = entry;
                else users[username] = entry;
                count++;
            }
            row = stmt.step();
        }
        // 群昵称：同一个人在群里的显示名可能与通讯录不同，群聊优先用群昵称。
        var roomStmt = db.prepare("SELECT username, hex(ext_buffer) FROM chat_room WHERE username IS NOT NULL;");
        var roomRow = roomStmt.step();
        var roomCount = 0;
        while (roomRow && roomCount < CONTACT_MAX_ENTRIES) {
            var roomID = roomRow[0] ? String(roomRow[0]) : "";
            if (roomID) {
                var members = contactParseGroupMembers(roomRow[1] ? String(roomRow[1]) : "");
                if (Object.keys(members).length > 0) {
                    if (!groups[roomID]) {
                        groups[roomID] = {
                            display: roomID,
                            nickname: "",
                            remark: "",
                            alias: ""
                        };
                    }
                    groups[roomID].members = members;
                }
                roomCount++;
            }
            roomRow = roomStmt.step();
        }
    } finally {
        try {
            if (db) db.close();
        } catch (e) { }
    }
    return { users: users, groups: groups, count: count };
}

function getContactDirectory(dbStoragePath) {
    var startedAt = Date.now();
    try {
        if (!contactDirectoryEnabled) return JSON.stringify({ ok: false, reason: "unsupported" });
        if (!contactState.installed) contactSetupHooks();
        if (!contactState.installed || !contactState.ccCrypt) return JSON.stringify({ ok: false, reason: "unsupported" });
        var base = String(dbStoragePath || "").replace(/\/+$/, "");
        if (!base) return JSON.stringify({ ok: false, reason: "db_missing" });
        var contactPath = base + "/contact/contact.db";
        var dbBytes;
        try {
            dbBytes = new Uint8Array(File.readAllBytes(contactPath));
        } catch (e) {
            return JSON.stringify({ ok: false, reason: "db_missing" });
        }
        if (dbBytes.length < CONTACT_PAGE_SIZE || dbBytes.length > CONTACT_MAX_DB_BYTES) {
            return JSON.stringify({ ok: false, reason: "db_missing" });
        }
        var resolved = contactResolveKeyByPage1(dbBytes.subarray(0, CONTACT_PAGE_SIZE));
        if (!resolved) {
            console.log("[!] [contact] 缺少 contact.db 密钥（需登录期 Hook 或打开一次通讯录/聊天触发页读）");
            return JSON.stringify({ ok: false, reason: "key_missing" });
        }
        var dec = contactDecryptDatabase(dbBytes, resolved.keyHex, contactPath);
        if (!dec) return JSON.stringify({ ok: false, reason: "decrypt_failed" });
        var tmpPath = contactWriteTempDb(dec.bytes, base);
        if (!tmpPath) return JSON.stringify({ ok: false, reason: "decrypt_failed" });
        var directory = null;
        try {
            directory = contactQueryDirectory(tmpPath);
        } finally {
            contactCleanupTempDb(tmpPath);
        }
        if (!directory) return JSON.stringify({ ok: false, reason: "decrypt_failed" });
        var keys = {};
        keys.contact = { salt: resolved.salt, key: resolved.keyHex };
        try {
            var sessionBytes = new Uint8Array(File.readAllBytes(base + "/session/session.db"));
            if (sessionBytes.length >= CONTACT_PAGE_SIZE) {
                var sessionKey = contactResolveKeyByPage1(sessionBytes.subarray(0, CONTACT_PAGE_SIZE));
                if (sessionKey) keys.session = { salt: sessionKey.salt, key: sessionKey.keyHex };
            }
        } catch (e) { /* session.db 可选 */ }
        var result = {
            ok: true,
            generated_at: Date.now(),
            wal_applied: dec.walApplied,
            users: directory.users,
            groups: directory.groups,
            keys: keys
        };
        var memberTotal = 0;
        for (var gid in directory.groups) {
            if (directory.groups[gid].members) memberTotal += Object.keys(directory.groups[gid].members).length;
        }
        contactDebug("目录完成 users=" + Object.keys(directory.users).length +
            " groups=" + Object.keys(directory.groups).length +
            " members=" + memberTotal +
            " wal=" + dec.walApplied + " ms=" + (Date.now() - startedAt));
        return JSON.stringify(result);
    } catch (e) {
        contactState.lastError = String(e);
        return JSON.stringify({ ok: false, reason: "decrypt_failed", message: String(e) });
    }
}

function setDbKeys(keysJson) {
    var accepted = 0;
    try {
        var obj = JSON.parse(String(keysJson || "{}"));
        for (var k in obj) {
            if (!Object.prototype.hasOwnProperty.call(obj, k)) continue;
            var item = obj[k];
            if (!item || !item.salt || !item.key) continue;
            if (String(item.key).length !== 64 || String(item.salt).length !== 32) continue;
            contactState.providedKeys[String(item.salt)] = String(item.key);
            contactNoteCandidate(String(item.key), "provided");
            accepted++;
        }
        contactDebug("回灌 DB key 缓存 accepted=" + accepted);
        return JSON.stringify({ ok: true, accepted: accepted });
    } catch (e) {
        contactState.lastError = String(e);
        return JSON.stringify({ ok: false, reason: "bad_json" });
    }
}

function getDbKeyStatus() {
    try {
        return JSON.stringify({
            installed: contactState.installed,
            validated: Object.keys(contactState.keysBySalt).length,
            candidates: contactState.candidates.length,
            passphrase: !!contactState.passphraseHex,
            last_error: contactState.lastError
        });
    } catch (e) {
        return JSON.stringify({ installed: false, error: String(e) });
    }
}
