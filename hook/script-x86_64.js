// WeChat 4.1.15.35 (270115), macOS x86_64. Receive + native text adapter.
// Offsets and instruction signatures were checked with Hopper MCP; see docs/intel-4.1.15.md.
if (Process.arch !== "x64") throw new Error("This Hook requires x64; got " + Process.arch);
var modules = Process.enumerateModules().filter(function(m) {
    return m.name === "wechat.dylib" && m.path.endsWith("{{.modulePathSuffix}}");
});
if (modules.length !== 1) throw new Error("Expected one Resources/wechat.dylib image");
var realModule = modules[0], baseAddr = realModule.base;
function moduleUUID(base) {
    if (base.readU32() !== 0xfeedfacf) throw new Error("Expected Mach-O 64 image");
    var cursor = base.add(32), count = base.add(16).readU32();
    for (var i = 0; i < count && i < 256; i++) {
        var cmd = cursor.readU32(), size = cursor.add(4).readU32();
        if (size < 8 || size > 65536) throw new Error("Invalid Mach-O load command");
        if (cmd === 0x1b) {
            var bytes = new Uint8Array(cursor.add(8).readByteArray(16));
            var hex = Array.prototype.map.call(bytes, function(x) { return ("0"+x.toString(16)).slice(-2); }).join("").toUpperCase();
            return [hex.slice(0,8),hex.slice(8,12),hex.slice(12,16),hex.slice(16,20),hex.slice(20)].join("-");
        }
        cursor = cursor.add(size);
    }
    throw new Error("LC_UUID missing");
}
var actualUUID = moduleUUID(baseAddr);
if (actualUUID !== "{{.moduleUUID}}") throw new Error("WeChat image UUID mismatch: " + actualUUID);
var messageFinalizerAddr = "{{.messageFinalizerAddr}}";
var messageVtableAddr = "{{.messageVtable}}";
var messageFinalizerEnabled = true;
var target = baseAddr.add(parseInt(messageFinalizerAddr,16));
var expectedBytes = "{{.messageFinalizerSignature}}".split(" ");
for (var i=0; i<expectedBytes.length; i++) {
    if (target.add(i).readU8() !== parseInt(expectedBytes[i],16)) throw new Error("Message finalizer signature mismatch");
}
var x64Health = { ready:false, arch:Process.arch, version:"{{.version}}", build:"{{.build}}",
    uuid:actualUUID, received:0, sendSupported:false,
    textSeed:false, voiceSend:false, voiceSeed:false, submitted:0, lastNativeTaskId:0 };
var incomingTrafficSeen = false;
function hookDebug() {}
function isReadablePointer(p) { try { return p && !p.isNull() && (p.readU8() >= 0); } catch(e) { return false; } }
// Intel libc++: short length = byte[0] >> 1; long = bit 0, size +8, data +16.
function readStdStringCompat(p, limit) {
    try {
        var tag=p.readU8(), longString=(tag&1)!==0;
        var size=longString?p.add(8).readU64().toNumber():(tag>>>1);
        if (size < 0 || size > (limit || 65536) || (!longString && size > 22)) return null;
        if (!size) return "";
        return (longString?p.add(16).readPointer():p.add(1)).readUtf8String(size);
    } catch(e) { return null; }
}
var INCOMING_SEEN_LIMIT = 4096;
var incomingMessageSeen = {};
var incomingSeenOrder = new Array(INCOMING_SEEN_LIMIT);
var incomingSeenCursor = 0;

function rememberIncomingMessage(serverId) {
    var evicted = incomingSeenOrder[incomingSeenCursor];
    if (evicted) delete incomingMessageSeen[evicted];
    incomingSeenOrder[incomingSeenCursor] = serverId;
    incomingMessageSeen[serverId] = true;
    incomingSeenCursor = (incomingSeenCursor + 1) % INCOMING_SEEN_LIMIT;
}


function parseMentionList(msgSource) {
    var mentions = [];
    if (!msgSource || typeof msgSource !== "string") return mentions;
    var listRe = /<atuserlist>([\s\S]*?)<\/atuserlist>/g;
    var listMatch;
    while ((listMatch = listRe.exec(msgSource)) !== null) {
        var body = listMatch[1] || "";
        body = body.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1");
        body = body.replace(/<[^>]+>/g, ",");
        var parts = body.split(/[,;\s]+/);
        for (var i = 0; i < parts.length; i++) {
            var value = parts[i].trim();
            if (value && mentions.indexOf(value) < 0) mentions.push(value);
        }
    }
    return mentions;
}

// 微信群 ID 契约：一律以 @chatroom 结尾（大小写不敏感）。hook 侧判群和清洗
// 拍一拍 <chatusername> 都用它：私聊时该字段是 wxid，直接当群 ID 会为好友
// 伪造出一个「群」会话（2026-10-21 修复）。
function isChatroomID(value) {
    if (!value || typeof value !== "string") return false;
    return /@chatroom$/i.test(value);
}

// 微信「拍一拍」在 4.1.15 以 appmsg（type=49，appmsg/type=62）下发，正文在 <title> 里。
// 提取标题后作为消息文本，聊天列表/规则引擎都能直接看到「拍了拍」。
function extractWeChatPatTitle(content) {
    if (!content || typeof content !== "string") return null;
    if (content.indexOf("拍了拍") < 0 &&
        content.indexOf("patted") < 0 &&
        content.indexOf("<type>62</type>") < 0) {
        return null;
    }
    var match = content.match(/<title>([\s\S]*?)<\/title>/);
    if (!match || !match[1]) return null;
    var title = decodeXmlText(match[1]);
    return title.length > 0 ? title : null;
}

function decodeXmlText(value) {
    if (!value) return "";
    return String(value)
        .replace(/&lt;/g, "<")
        .replace(/&gt;/g, ">")
        .replace(/&quot;/g, '"')
        .replace(/&apos;/g, "'")
        .replace(/&amp;/g, "&");
}

// 从 appmsg/patinfo（4.1.15）或 sysmsg/pat（4.1.12 及更早）解析「谁拍了谁」。
// 规则层必须用 target_wxid 判断是否拍的是机器人：只看标题里的「拍了拍」会把
// 群里拍别人的消息也当成唤醒（2026-10-21 修复）。
function extractWeChatPatInfo(content) {
    if (!content || typeof content !== "string") return null;
    var block = null;
    var infoMatch = content.match(/<patinfo>([\s\S]*?)<\/patinfo>/i);
    if (infoMatch) {
        block = infoMatch[1];
    } else {
        var patMatch = content.match(/<pat>([\s\S]*?)<\/pat>/i) ||
            content.match(/<patmsg>([\s\S]*?)<\/patmsg>/i);
        if (patMatch) block = patMatch[1];
    }
    if (!block) return null;
    function pick(name) {
        var match = block.match(new RegExp("<" + name + "[^>]*>([\\s\\S]*?)</" + name + ">", "i"));
        return match && match[1] ? decodeXmlText(match[1]).trim() : "";
    }
    var target = pick("pattedusername");
    if (!target) return null;
    return {
        from_wxid: pick("fromusername"),
        chat_wxid: pick("chatusername"),
        target_wxid: target,
        suffix: pick("patsuffix"),
        template: pick("template")
    };
}

function attachMessageFinalizer() {
    if (!messageFinalizerEnabled) {
        console.log("[!] 入站消息接收: messageFinalizer 未配置, 跳过");
        return;
    }
    try {
        var finalizerPtr = baseAddr.add(parseInt(messageFinalizerAddr, 16));
        var expectedVtable = null;
        try { expectedVtable = baseAddr.add(parseInt(messageVtableAddr, 16)); } catch (e) { expectedVtable = null; }
        console.log("[+] 入站消息接收: hook Message finalizer @ " + finalizerPtr +
            " (layout=" + "v4_1_15_x64" + ", vtable=" + messageVtableAddr + ")");
        var listener = Interceptor.attach(finalizerPtr, {
            onEnter: function (args) {
                try {
                    var mode = args[1].toInt32();
                    if (mode !== 1) return;
                    var obj = args[0];
                    if (!isReadablePointer(obj) || !obj.readPointer().equals(expectedVtable)) return;
                    // 定长字段先读并按 serverId 去重：历史回放时同一条消息可能被重复
                    // finalize，重复命中直接返回，不再做字符串拷贝/正则/JSON。
                    var type = obj.add(0x0c).readU32();
                    var created = obj.add(0x114).readU32();
                    var serverId = obj.add(0xf8).readU64().toString();
                    if (serverId !== "0" && incomingMessageSeen[serverId]) return;
                    var from = readStdStringCompat(obj.add(0x18), 256);
                    var to = readStdStringCompat(obj.add(0x30), 256);
                    var content = readStdStringCompat(obj.add(0x130), 4 * 1024 * 1024);
                    if (from === null || to === null || content === null) return;
                    if (!from || !to) return;
                    // 能 finalize 出真实消息 = 已登录且消息链路稳定。提前解除 CdnManager
                    // 冷启动的「登录稳定门禁」，避免 bridge 启动 60s 内收到图片时
                    // triggerDownload 直接返回 fail（图片获取失败）。
                    incomingTrafficSeen = true;
                    if (serverId !== "0") rememberIncomingMessage(serverId);
                    var group = "";
                    var user = from;
                    var text = content;
                    var nickname = from;
                    var member = "";
                    var msgSource = "";
                    var mentions = [];
                    // 普通消息不做 patinfo 正则；4.1.15 拍一拍是 type=49，旧版 sysmsg
                    // 则含 patinfo/pattedusername 标记。用轻量 indexOf 先筛。
                    var patInfo = null;
                    if (type === 49 || content.indexOf("patinfo") >= 0 ||
                        content.indexOf("pattedusername") >= 0 || content.indexOf("patmsg") >= 0) {
                        patInfo = extractWeChatPatInfo(content);
                    }
                    // 判群：from 或 to 任一以 @chatroom 结尾。入站群消息 from=群；
                    // 自己发出的群消息 from=自己、to=群。只有 from 是群时才需要读
                    // 群成员/正文前缀；仅 to 是群时只置 group，不做成员解析。
                    if (isChatroomID(from)) {
                        // 群消息的真实发送者 wxid 在 +0x48；@ 目标列表在 +0x160 的
                        // <atuserlist>。私聊不需要这两次字符串读取（历史回放时省开销）。
                        member = readStdStringCompat(obj.add(0x48), 256) || "";
                        msgSource = readStdStringCompat(obj.add(0x160), 64 * 1024) || "";
                        mentions = parseMentionList(msgSource);
                        group = from;
                        if (member.indexOf("wxid_") === 0) user = member;
                        var prefixes = [user + ": ", user + ":\n"];
                        var stripped = false;
                        for (var pi = 0; pi < prefixes.length; pi++) {
                            if (content.indexOf(prefixes[pi]) === 0) {
                                text = content.substring(prefixes[pi].length);
                                stripped = true;
                                break;
                            }
                        }
                        if (!stripped) {
                            var split = content.indexOf(":\n");
                            if (split > 0 && split < 200) {
                                user = content.substring(0, split);
                                text = content.substring(split + 2);
                                nickname = user;
                            }
                        }
                        if (!nickname || nickname === from) nickname = user;
                    } else if (isChatroomID(to)) {
                        // 自己发出的群消息：from=自己、to=群；不能按私聊处理，
                        // 否则会被归进「自己 wxid」的会话（2026-10-21 修复）。
                        group = to;
                    }
                    // 拍一拍 appmsg 的 from/to 可能是群 ID（群内拍人），也可能是
                    // 私聊双方的 wxid。真实拍人者/被拍者在 <patinfo> 里，优先采用，
                    // 供 App 判定「是否拍的是机器人」。
                    if (patInfo) {
                        if (patInfo.from_wxid && patInfo.from_wxid.indexOf("wxid_") === 0) {
                            user = patInfo.from_wxid;
                            if (!member) member = user;
                            nickname = user;
                        }
                        // 只有 <chatusername> 是合法群 ID 时才当群：私聊拍一拍里它是
                        // wxid，旧逻辑会据此伪造群会话（2026-10-21 修复）。
                        if (!group && isChatroomID(patInfo.chat_wxid)) group = patInfo.chat_wxid;
                    }
                    var shown = text;
                    if (type === 3) shown = "[图片]";
                    else if (type === 34) shown = "[语音]";
                    else if (type === 43) shown = "[视频]";
                    else if (type === 47) shown = "[表情]";
                    else if (type === 49) {
                        var patTitle = extractWeChatPatTitle(content);
                        shown = patTitle ? patTitle : "[链接/文件]";
                    }
                    if (msgSource.indexOf("<atuserlist>") >= 0 && mentions.length === 0) {
                        console.log("[!] atuserlist 非空但未解析出目标: " + msgSource.substring(0, 240));
                    }
                    // 逐条日志在历史回放时每条会多一次 Frida IPC，默认关闭（HOOK_DEBUG=1 打开）。
                    hookDebug("[+] incoming message: type=" + type + " from=" + from +
                        " group=" + group + " len=" + text.length + " id=" + serverId +
                        " mentions=" + mentions.length);
                    var payload = {
                        // self_id 仅作为兜底；bridge 会用当前账号把它改写成
                        // 「自己」，并结合 from/to/sender_wxid 判定 is_self。
                        self_id: to,
                        user_id: user,
                        group_id: group,
                        from_wxid: from,
                        to_wxid: to,
                        sender_wxid: user,
                        member_wxid: member,
                        sender: { user_id: user, nickname: nickname },
                        time: created * 1000,
                        post_type: "message",
                        message_id: serverId,
                        message: [{ type: "text", data: { text: shown } }].concat(mentions.map(function (wxid) {
                            return { type: "at", data: { qq: wxid } };
                        })),
                        mentions: mentions,
                        raw_message: text,
                        show_content: shown,
                        message_type: group ? "group" : "private",
                        msg_type: type
                    };
                    if (patInfo) {
                        payload.pat_from_wxid = patInfo.from_wxid || user;
                        // 契约：pat_chat_wxid 是群 ID（私聊为空），与 group 保持一致。
                        payload.pat_chat_wxid = group;
                        payload.pat_target_wxid = patInfo.target_wxid;
                        if (patInfo.suffix) payload.pat_suffix = patInfo.suffix;
                        if (patInfo.template) payload.pat_template = patInfo.template;
                    }
                    x64Health.received++;
                    send({ type: "incoming_message", payload: payload });
                } catch (e) {
                    console.log("[!] incoming message parse error: " + e);
                }
            }
        });
    } catch (e) {
        throw e;
    }
}
// Native Task owns its protobuf/string allocations. After submission the service owns
// the Task: never replay a captured task or copy its std::function/shared_ptr members.
var x64CompletionHelper = null;
function x64InitNativeHelper(path) {
    if ("{{.enableSend}}" !== "true") return "off";
    var module = Module.load(path);
    var abi = new NativeFunction(module.getExportByName("wechat_x64_completion_abi"), "uint", []);
    if (abi() !== 1) throw new Error("Unsupported x64 completion ABI");
    x64CompletionHelper = {
        module:module,
        init:new NativeFunction(module.getExportByName("wechat_x64_completion_init"), "void", ["pointer"]),
        count:new NativeFunction(module.getExportByName("wechat_x64_completion_count"), "uint", []),
        errorType:new NativeFunction(module.getExportByName("wechat_x64_completion_error_type"), "int", []),
        errorCode:new NativeFunction(module.getExportByName("wechat_x64_completion_error_code"), "int", [])
    };
    x64CompletionHelper.baseline = x64CompletionHelper.count();
    x64Health.sendSupported = true;
    return "1";
}
function x64Native(rva, result, args) {
    return new NativeFunction(baseAddr.add(parseInt(rva, 16)), result, args);
}
function x64HexBytes(hex) {
    if (typeof hex !== "string" || !hex.length || hex.length > 8 * 1024 * 1024 ||
        hex.length % 2 || !/^[0-9a-f]+$/i.test(hex)) throw new Error("Invalid text protobuf");
    var bytes = [];
    for (var i = 0; i < hex.length; i += 2) bytes.push(parseInt(hex.slice(i, i + 2), 16));
    return bytes;
}
function x64PrepareText(protoHex) {
    if (!x64CompletionHelper) throw new Error("Native completion helper not loaded");
    var bytes = x64HexBytes(protoHex), task = null;
    var options = Memory.alloc(0x38);
    // Use the native descriptor initializer (opcode 0x20a, URL, default flags).
    x64Native("{{.textDescriptorCtorAddr}}", "pointer", ["pointer"])(options);
    try {
        task = x64Native("{{.operatorNewAddr}}", "pointer", ["ulong"])(0xf0);
        x64Native("{{.textTaskCtorAddr}}", "void", ["pointer", "pointer"])(task, options);
        x64CompletionHelper.init(task);
    } finally {
        // The Task constructor copied the URL; free only the descriptor's allocation.
        if (options.add(0x18).readU8() & 1) {
            x64Native("{{.operatorDeleteAddr}}", "void", ["pointer", "ulong"])(
                options.add(0x28).readPointer(), options.add(0x18).readU64().toNumber() - 1);
        }
    }
    try {
        var buffer = Memory.alloc(bytes.length); buffer.writeByteArray(bytes);
        var parsed = x64Native("{{.protobufParseAddr}}", "bool", ["pointer", "pointer", "int"])(
            task.add(0x88), buffer, bytes.length);
        if (!parsed) throw new Error("Native text protobuf parse failed");
        var output = Memory.alloc(24);
        x64Native("{{.protobufSerializeAddr}}", "pointer", ["pointer", "pointer"])(output, task.add(0x88));
        try {
            var tag = output.readU8(), size = (tag & 1) ? output.add(8).readU64().toNumber() : tag >>> 1;
            if (size !== bytes.length) throw new Error("Native protobuf changed length (check 32-bit clientmsgid)");
            var data = (tag & 1) ? output.add(16).readPointer() : output.add(1);
            var actual = new Uint8Array(data.readByteArray(size));
            for (var i = 0; i < size; i++) {
                if (actual[i] !== bytes[i]) throw new Error("Native protobuf roundtrip mismatch");
            }
        } finally {
            if (output.readU8() & 1) {
                x64Native("{{.operatorDeleteAddr}}", "void", ["pointer", "ulong"])(
                    output.add(16).readPointer(), output.readU64().toNumber() - 1);
            }
        }
        return task;
    } catch (error) {
        x64Native("{{.textTaskDeleteAddr}}", "void", ["pointer"])(task);
        throw error;
    }
}
function x64TextService() {
    var root = baseAddr.add(parseInt("{{.serviceRootAddr}}", 16)).readPointer();
    var getter = root.readPointer().add(0x18).readPointer();
    if (!getter.equals(baseAddr.add(parseInt("{{.textServiceGetterAddr}}", 16)))) throw new Error("Unexpected text service getter");
    var service = new NativeFunction(getter, "pointer", ["pointer"])(root);
    if (service.isNull() || !service.readPointer().equals(baseAddr.add(parseInt("{{.textServiceVtable}}", 16)))) {
        throw new Error("Unexpected text service vtable");
    }
    var submit = service.readPointer().add(0x28).readPointer();
    if (!submit.equals(baseAddr.add(parseInt("{{.textSubmitAddr}}", 16)))) throw new Error("Unexpected text submit thunk");
    return { pointer:service, submit:submit };
}
function x64ValidateText(protoHex) {
    var task = x64PrepareText(protoHex);
    try {
        x64TextService();
        // Exercise exactly the service's completion ABI, then its virtual destructor,
        // without registering a network Task. An empty completion would throw here.
        var callback = task.add(0x70).readPointer();
        var taskRef = Memory.alloc(8); taskRef.writePointer(task);
        var type = Memory.alloc(4), code = Memory.alloc(4);
        var invoke = new NativeFunction(callback.readPointer().add(0x30).readPointer(), "bool",
            ["pointer", "pointer", "pointer", "pointer"]);
        if (!invoke(callback, taskRef, type, code)) throw new Error("Native completion did not release Task");
        return "1";
    }
    finally { x64Native("{{.textTaskDeleteAddr}}", "void", ["pointer"])(task); }
}
function x64SendText(taskId, receiver, content, atUser, protoHex) {
    if (!x64Health.sendSupported) return "off";
    var task = null, transferred = false;
    try {
        var service = x64TextService();
        task = x64PrepareText(protoHex);
        // Transfer once. If the native call throws, ownership may already have moved.
        transferred = true;
        new NativeFunction(service.submit, "void", ["pointer", "pointer"])(service.pointer, task);
        var nativeTaskId = task.add(8).readU32();
        if (!nativeTaskId) throw new Error("Text service did not assign a task ID");
        x64Health.lastNativeTaskId = nativeTaskId;
        x64Health.submitted++;
        return "1"; // queued; delivery is asynchronous, as on the arm64 bridge path
    } catch (error) {
        if (task && !transferred) x64Native("{{.textTaskDeleteAddr}}", "void", ["pointer"])(task);
        console.log("[!] x64 native text: " + error);
        return "fail";
    }
}
// Media and Moments stay unavailable until their own ABI is verified. Contact DB reads use
// the separate CommonCrypto/SQLCipher helper concatenated by bridge/loadJs (no WeChat RVA).
function unavailable() { return "off"; }
function x64Status() {
    if (x64CompletionHelper) {
        x64Health.completed = x64CompletionHelper.count() - x64CompletionHelper.baseline;
        x64Health.lastErrorType = x64CompletionHelper.errorType();
        x64Health.lastErrorCode = x64CompletionHelper.errorCode();
    }
    return JSON.stringify(x64Health);
}
rpc.exports = {
    x64Status:x64Status,
    x64ValidateText:x64ValidateText,
    x64InitNativeHelper:x64InitNativeHelper,
    r3VoiceDiag:x64Status,
    r3Status:x64Status,
    r3RestoreSeed:unavailable, r3RestoreVoiceSeed:unavailable, r3RestoreVoiceHeader:unavailable,
    r3VoiceHeader:function() { return ""; }, setDbKeys:setDbKeys,
    getContactDirectory:getContactDirectory, getDbKeyStatus:getDbKeyStatus,
    snsStatus:function() { return JSON.stringify({ok:false,enabled:false,error:"x64_sns_unverified"}); },
    triggerSendTextMessage:x64SendText, triggerSendReplyMessage:unavailable,
    triggerSendImgMessage:unavailable, triggerSendVideoMessage:unavailable,
    triggerSendVoiceMessage:unavailable, triggerSendFileMessage:unavailable,
    triggerSendFileUploadMessage:unavailable, triggerUploadImg:unavailable,
    triggerUploadVideo:unavailable, triggerUploadVoice:unavailable,
    triggerUploadFile:unavailable, triggerUploadAppAttach:unavailable, triggerDownload:unavailable
};
attachMessageFinalizer();
x64Health.ready = true;
console.log("[+] x64 Hook ready: WeChat {{.version}} ({{.build}}), textSend=" + x64Health.sendSupported + ", image=" + actualUUID);
