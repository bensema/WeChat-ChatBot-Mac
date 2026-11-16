const assert = require('node:assert/strict');
const { test } = require('node:test');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const config = JSON.parse(fs.readFileSync(path.join(__dirname, '../versions/4_1_15_35_x86_64.json')));
const contactModule = fs.readFileSync(path.join(__dirname, '../contact-directory-x64.js'), 'utf8');
let script = contactModule + '\n' + fs.readFileSync(path.join(__dirname, '../script-x86_64.js'), 'utf8');
for (const [key, value] of Object.entries(config)) script = script.split('{{.'+key+'}}').join(value);

// A sparse Frida memory fixture exercises the emitted OneBot events and identity guards.
function fixture(options = {}) {
  const blocks = [];
  const events = [];
  let next = 0x200000000n, listener;
  class Pointer {
    constructor(value) { this.value = BigInt(value); }
    add(n) { return new Pointer(this.value + BigInt(n)); }
    sub(n) { return new Pointer(this.value - (n instanceof Pointer ? n.value : BigInt(n))); }
    equals(other) { return this.value === other.value; }
    isNull() { return this.value === 0n; }
    toString() { return '0x'+this.value.toString(16); }
    toInt32() { return Number(BigInt.asIntN(32, this.value)); }
    location(size) {
      const b = blocks.find(b => this.value >= b.address && this.value + BigInt(size) <= b.address + BigInt(b.data.length));
      if (!b) throw new Error('unreadable memory');
      return [b.data, Number(this.value-b.address)];
    }
    readU8() { const [b,p]=this.location(1); return b[p]; }
    readU32() { const [b,p]=this.location(4); return b.readUInt32LE(p); }
    readU64() { const [b,p]=this.location(8); const n=b.readBigUInt64LE(p); return {toNumber:()=>Number(n),toString:()=>n.toString()}; }
    readPointer() { const [b,p]=this.location(8); return new Pointer(b.readBigUInt64LE(p)); }
    readByteArray(n) { const [b,p]=this.location(n); return Uint8Array.from(b.subarray(p,p+n)).buffer; }
    readUtf8String(n) { const [b,p]=this.location(n); return b.subarray(p,p+n).toString('utf8'); }
  }
  function block(address, size) { const data=Buffer.alloc(size); blocks.push({address:BigInt(address),data}); return data; }
  function allocate(size) { const address=next; next+=BigInt(size+32); return [new Pointer(address), block(address,size)]; }
  const base = new Pointer(0x100000000n);
  const header=block(base.value,64);header.writeUInt32LE(0xfeedfacf,0);header.writeUInt32LE(1,16);header.writeUInt32LE(0x1b,32);header.writeUInt32LE(24,36);
  Buffer.from(config.moduleUUID.replaceAll('-',''),'hex').copy(header,40);
  if(options.badUUID)header[40]^=1;
  const signature=block(base.value+BigInt(config.messageFinalizerAddr),14);
  Buffer.from(config.messageFinalizerSignature.split(' ').map(x=>parseInt(x,16))).copy(signature);
  if(options.badSignature)signature[0]^=1;
  const context={rpc:{},Process:{arch:options.arch||'x64',enumerateModules:()=>[{name:'wechat.dylib',path:'/Applications/WeChat.app'+config.modulePathSuffix,base,size:0xa3e1000}]},
    Interceptor:{attach:(target,callbacks)=>{
      if(target.equals(base.add(BigInt(config.messageFinalizerAddr))))listener=callbacks;
    }},console:{log(){}},send:e=>events.push(e)};
  vm.runInNewContext(script,context);
  function stringAt(object,data,offset,value) {
    const bytes=Buffer.from(value,'utf8');
    if(bytes.length<=22){data[offset]=bytes.length*2;bytes.copy(data,offset+1);}
    else {const [p,b]=allocate(bytes.length+1);bytes.copy(b);data.writeBigUInt64LE(BigInt(bytes.length+1)|1n,offset);data.writeBigUInt64LE(BigInt(bytes.length),offset+8);data.writeBigUInt64LE(p.value,offset+16);}
  }
  function message({id=1,from='wxid_friend',to='wxid_self',member='',text='hello',source='',mode=1}={}) {
    const [object,data]=allocate(0x260);
    data.writeBigUInt64LE(base.value+BigInt(config.messageVtable),0);data.writeUInt32LE(1,12);data.writeBigUInt64LE(BigInt(id),0xf8);data.writeUInt32LE(1794670000,0x114);
    for(const [off,value] of [[0x18,from],[0x30,to],[0x48,member],[0x130,text],[0x160,source]])stringAt(object,data,off,value);
    listener.onEnter.call({},[object,new Pointer(mode)]);
  }
  return {context,events,message};
}

test('private text reaches the existing incoming_message contract; repeats are bounded and deduplicated',()=>{
  const f=fixture(); f.message(); f.message();
  assert.equal(f.events.length,1);assert.equal(f.events[0].type,'incoming_message');
  assert.equal(f.events[0].payload.raw_message,'hello');assert.equal(f.events[0].payload.from_wxid,'wxid_friend');
  assert.equal(JSON.parse(f.context.rpc.exports.x64Status()).received,1);
});
test('Intel long UTF-8 strings, group members and mentions preserve content',()=>{
  const f=fixture();const text='你好，来自 Intel 的群聊消息。'.repeat(4);
  f.message({from:'group@chatroom',member:'wxid_member',text:'wxid_member:\n'+text,source:'<msgsource><atuserlist><![CDATA[wxid_self]]></atuserlist></msgsource>'});
  assert.equal(f.events.length,1);const p=f.events[0].payload;
  assert.equal(p.group_id,'group@chatroom');assert.equal(p.user_id,'wxid_member');assert.equal(p.raw_message,text);
  assert.deepEqual(Array.from(p.mentions),['wxid_self']);
});
test('self group messages and non-finalizing calls are routed correctly',()=>{
  const f=fixture();f.message({mode:0});assert.equal(f.events.length,0);
  f.message({from:'wxid_self',to:'group@chatroom'});assert.equal(f.events[0].payload.group_id,'group@chatroom');
  assert.equal(f.context.rpc.exports.triggerSendTextMessage(),'off');
  assert.equal(f.context.rpc.exports.triggerSendImgMessage(),'off');
});
test('wrong architecture, UUID or instruction bytes abort before installing hooks',()=>{
  assert.throws(()=>fixture({arch:'arm64'}),/requires x64/);
  assert.throws(()=>fixture({badUUID:true}),/UUID mismatch/);
  assert.throws(()=>fixture({badSignature:true}),/signature mismatch/);
});
