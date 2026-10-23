const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require(process.env.TYPESCRIPT_MODULE || 'typescript');
const source=fs.readFileSync('entry/src/main/ets/component/WebInteractionScripts.ets','utf8');
const out={exports:{}};vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS}}).outputText,{module:out,exports:out.exports});
const {CHAT_INPUT_FOCUS_JS,HOVER_FIX_JS}=out.exports;
let now=10000,focusCalls=0,blurCalls=0;const events={};
class Element {
 constructor(kind){this.kind=kind;this.tagName=['search','checkbox'].includes(kind)?'INPUT':kind==='old'?'TEXTAREA':'DIV';this.type=kind;}
 closest(){return ['old','new','search','checkbox'].includes(this.kind)?this:null;}
 focus(){focusCalls++;document.activeElement=this;}
 blur(){blurCalls++;document.activeElement=null;}
}
const document={activeElement:null,addEventListener:(name,fn)=>events[name]=fn};
vm.runInNewContext(CHAT_INPUT_FOCUS_JS,{window:{},document,HTMLElement:Element,Date:{now:()=>now}});
for(const kind of ['old','new','search']){
 const editor=new Element(kind);const before=focusCalls;editor.focus();assert.equal(focusCalls,before,'automatic focus blocked');
 events.pointerdown({isTrusted:true,target:editor});editor.focus();assert.equal(focusCalls,before+1,'manual input allowed');
 const different=new Element('search');different.focus();assert.equal(focusCalls,before+1,'touch authorizes only the selected field');
 events.pointerdown({isTrusted:true,target:new Element('other')});assert.equal(document.activeElement,null,'navigation blurs composer');editor.focus();assert.equal(focusCalls,before+1,'navigation cannot reopen keyboard');
 now+=2000;
}
const checkbox=new Element('checkbox');checkbox.focus();assert.equal(document.activeElement,checkbox,'non-text controls retain focus behavior');
now+=2000;const search=new Element('search');document.activeElement=search;events.focusin({target:search});assert.equal(document.activeElement,null,'native autofocus is blurred');
events.keydown({isTrusted:true,key:'Tab',target:new Element('other')});search.focus();assert.equal(document.activeElement,search,'physical keyboard Tab stays usable');
const mobile={matchMedia:q=>({matches:q==='(pointer: coarse)'})};vm.runInNewContext(HOVER_FIX_JS,{window:mobile});
assert.equal(mobile.matchMedia('(hover: hover)').matches,false);assert.equal(mobile.matchMedia('(hover: none)').matches,true);
assert.equal(mobile.matchMedia('(any-hover: none)').matches,true);

// ---- 注入脚本必须能被解析 ----
// 这些脚本是"拼在一整行里的 JS"，一旦有人在字符串里写了 // 行注释，
// 后面所有代码都会被注释掉，浏览器只报 "Unexpected end of input"，线上极难定位。
// 真机上已经踩过一次（下拉刷新整段失效），这里把语法检查固化下来。
const perfSource=fs.readFileSync('entry/src/main/ets/component/WebPerformanceScripts.ets','utf8');
const perfOut={exports:{}};
vm.runInNewContext(ts.transpileModule(perfSource,{compilerOptions:{module:ts.ModuleKind.CommonJS}}).outputText,
  {module:perfOut,exports:perfOut.exports});
for(const [name,code] of [...Object.entries(out.exports),...Object.entries(perfOut.exports)]){
  if(!name.endsWith('_JS')) continue;
  assert.doesNotThrow(()=>new vm.Script(code),name+' must be valid JS');
  // 字符串里出现 http:// 这类 URL 是合法的，这里只拦"行内注释"：// 出现在引号之外。
  let quoted=null;
  for(let i=0;i<code.length;i++){
    const c=code[i];
    if(quoted){ if(c==='\\'){i++;continue;} if(c===quoted)quoted=null; continue; }
    if(c==='"'||c==="'"||c==='`'){quoted=c;continue;}
    if(c==='/'&&code[i+1]==='/'){assert.fail(name+' contains a line comment at '+i);}
  }
}
assert(out.exports.PULL_REFRESH_JS.includes('onPullRefresh'),'pull refresh must call the native bridge');
assert(out.exports.PULL_REFRESH_JS.includes('touchstart'),'pull refresh must listen to touch');
console.log('PASS: composer/settings search autofocus blocked, manual input/Tab allowed, navigation blur, hover query semantics, injected scripts parse');
