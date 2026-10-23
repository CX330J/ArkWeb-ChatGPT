/** 网页输入框只接受用户主动聚焦，覆盖聊天、设置搜索和网页弹窗。 */
export const CHAT_INPUT_FOCUS_JS: string = '(function(){'
  + 'if(window.__ohosInputFocus)return;window.__ohosInputFocus=1;'
  + 'var intent=0,intentField=null,tabIntent=0;'
  + 'function editable(el){if(!el||!el.closest)return null;'
  + 'var field=el.closest("input,textarea,[contenteditable]:not([contenteditable=false])");'
  + 'if(field&&field.tagName==="INPUT"&&/^(button|submit|reset|checkbox|radio|range|color|file|image|hidden)$/i.test(field.type))return null;return field;}'
  + 'function allowed(field){return field===intentField&&Date.now()-intent<1200||Date.now()-tabIntent<1200;}'
  // 点击发送/提交按钮时不能在 pointerdown 阶段先 blur 输入框。
  // blur 会让 ArkWeb 先收起输入法，部分移动端页面随后重建提交按钮，导致同一次触摸
  // 没有机会继续派发 click，表现为“第一次只收键盘，第二次才发送”。
  // 非操作控件仍保留主动失焦，避免点到空白处时键盘一直挡住页面。
  + 'function action(el){return !!(el&&el.closest&&el.closest("button,a,[role=button],[type=submit],[data-testid*=send]"));}'
  + 'document.addEventListener("pointerdown",function(e){intentField=e.isTrusted?editable(e.target):null;intent=intentField?Date.now():0;tabIntent=0;'
  + 'var active=editable(document.activeElement);if(active&&active!==intentField&&!action(e.target))active.blur();},{capture:true,passive:true});'
  + 'document.addEventListener("keydown",function(e){if(!e.isTrusted)return;if(e.key==="Tab")tabIntent=Date.now();'
  + 'else if(editable(e.target)){intentField=editable(e.target);intent=Date.now();}},true);'
  + 'var original=HTMLElement.prototype.focus;'
  + 'HTMLElement.prototype.focus=function(){var field=editable(this);if(field&&!allowed(field))return;return original.apply(this,arguments);};'
  + 'document.addEventListener("focusin",function(e){var field=editable(e.target);if(field&&!allowed(field))field.blur();},true);'
  + '})();';

/** 手机点击去掉双击缩放等待；保留文本选择、原生滚动和手动输入。 */
export const TOUCH_RESPONSE_CSS: string =
  'button,a,[role="button"]{touch-action:manipulation;}'
  + '@media (prefers-reduced-motion:reduce){html{scroll-behavior:auto;}}';

/**
 * 长距离下拉刷新。
 *
 * 只有同时满足下面三条才触发，避免和网页自身的滚动/选择/拖拽打架：
 *   1) 手指按下时，事件起点所在的滚动容器已经在顶部（scrollTop <= 0）；页面中途滑到顶不算，
 *      否则正常向上滚动会不断触发刷新；
 *   2) 向下拖动距离达到阈值（默认 180px）—— 用户要的是"下滑距离很长"才刷新；
 *   3) 拖动方向以纵向为主（|dy| > |dx| * 1.5），斜着划不触发。
 *
 * 为什么用 touchstart/touchmove 的 capture 阶段：
 *   ChatGPT 自己会在某些容器上 preventDefault 吞掉触摸事件；在 capture 上先看一眼
 *   不影响它后续的处理（这里从不 preventDefault，只是记录）。
 *
 * 下拉过程中的视觉反馈是一个固定在顶部中央的圆环：外圈是固定的轨道，内圈是环形进度，
 * 随下拉距离从 0 长到 100%，到 100% 时圆环变绿并显示"松开刷新"的提示。
 * 它是独立于网页 DOM 的一个 fixed 元素，不插入网页列表、不引起 React 重新渲染、不参与布局；
 * 位移用 transform（合成层），进度用 stroke-dashoffset（只重绘不重排），
 * 都是滚动中代价最低的写法。
 *
 * 与 ArkTS 侧手势屏蔽的关系：
 *   onGestureRecognizerJudgeBegin 拦的是 PAN/DRAG/LONG_PRESS 手势识别器（原生侧），
 *   本脚本只读 touch 坐标、不回传任何拦截，两者互不干扰，原有屏蔽行为保持不变。
 */
export const PULL_REFRESH_JS: string = '(function(){'
  + 'if(window.__ohosPullRefresh)return;window.__ohosPullRefresh=1;'
  + 'var THRESHOLD=180,MAX_DY=420,GAP=1200;'
  + 'var startY=0,startX=0,tracking=false,armed=false,dy=0,lastFire=0;'
  + 'var bar=null,arc=null;'
  + 'function scroller(el){'
  + 'while(el&&el!==document.body&&el!==document.documentElement){'
  + 'var s=getComputedStyle(el);'
  + 'if(/(auto|scroll|overlay)/.test(s.overflowY)&&el.scrollHeight>el.clientHeight+1)return el;'
  + 'el=el.parentElement;}'
  + 'return document.scrollingElement||document.documentElement;}'
  + 'function atTop(el){'
  + 'if(el===document.scrollingElement||el===document.documentElement||el===document.body)'
  + 'return (window.scrollY||document.documentElement.scrollTop||0)<=0;'
  + 'return el.scrollTop<=0;}'
  // 圆环尺寸与 SVG 周长：r=18 -> 周长 2*pi*r ≈ 113.1，用来换算 dashoffset。
  // 整段都是网页侧 JS 字符串，字符串里的变量必须用 JS 侧声明，
  // 不能直接拼接 TS 常量的值（这里曾误写成 TS 变量，编译期找不到名字）。
  + 'var R=18,CIRC=2*Math.PI*R;'
  + 'function ensureBar(){'
  + 'if(bar)return bar;'
  + 'bar=document.createElement("div");bar.id="ohos-pull-refresh";'
  // 用 SVG 画环：两个 circle 共享圆心，轨道固定、进度圈的 dasharray/dashoffset 控制长度。
  // 初始 translateY(-56px) 收在屏幕上方，下拉时才滑下来。
  + 'bar.style.cssText="position:fixed;left:50%;top:0;width:44px;height:44px;margin-left:-22px;'
  + 'z-index:2147483647;pointer-events:none;opacity:0;'
  + 'transform:translateY(-44px);will-change:transform,opacity;";'
  + 'bar.innerHTML='
  + '"<svg viewBox=\\\"0 0 44 44\\\" width=\\\"44\\\" height=\\\"44\\\" style=\\\"display:block;overflow:visible\\\">"'
  + '+"<circle cx=\\\"22\\\" cy=\\\"22\\\" r=\\\"18\\\" fill=\\\"none\\\" stroke=\\\"rgba(128,128,128,.28)\\\" stroke-width=\\\"3\\\"/>"'
  + '+"<circle id=\\\"ohos-pull-arc\\\" cx=\\\"22\\\" cy=\\\"22\\\" r=\\\"18\\\" fill=\\\"none\\\" stroke=\\\"#10a37f\\\" stroke-width=\\\"3\\\"'
  + ' stroke-linecap=\\\"round\\\" stroke-dasharray=\\\"113.1\\\" stroke-dashoffset=\\\"113.1\\\"'
  + ' transform=\\\"rotate(-90 22 22)\\\" style=\\\"transition:stroke .15s linear\\\"/>"'
  + '+"</svg>";'
  // 挂到 body：documentElement 上若被站点设了 transform/filter 会形成层叠上下文，
  // 把 fixed 子元素关进去，看起来就是"元素存在但看不见"。
  + '(document.body||document.documentElement).appendChild(bar);'
  + 'arc=bar.querySelector("#ohos-pull-arc");'
  + 'return bar;}'
  + 'function paint(p){'
  + 'var b=ensureBar(),shown=p>0;'
  + 'var ratio=Math.min(1,p);'
  // 透明背景 + 浅色卡片：无论网页是深色还是浅色都能看清，不需要读网页主题。
  + 'b.style.opacity=shown?"1":"0";'
  // 淡入用 transition：从 0 到 0.02 的第一帧不会"啪"地闪一下。
  + 'b.style.transition="opacity .1s linear";'
  // 透明背景 + 圆环本体：无论网页深色浅色都能看清，不需要读网页主题。
  // 外层的 rotate 只是装饰性的转动，实际进度由内圈 dashoffset 表达。
  // 【可见性】起点必须让圆环在"刚开始下拉"时就露出来：
  //   原先写成 -56 + ratio*72，要 ratio≈0.78（下拉 140px）才进入屏幕，
  //   在那之前用户完全看不到任何反馈，像是"没有这个功能"。
  //   现在 -0.24 + ratio*1.18：ratio=0.13（下拉 23px）就开始露头，
  //   到 100% 时整体在屏幕内 52px 处，一直在视野里。
  + 'b.style.transform="translateY("+((ratio*1.18-0.24)*44).toFixed(1)+"px) rotate("+(ratio*220).toFixed(0)+"deg)";'
  + 'if(arc){'
  + 'arc.setAttribute("stroke-dashoffset",(CIRC*(1-ratio)).toFixed(1));'
  // 到 100% 换成更亮的绿色，提示"可以松手了"。
  + 'arc.setAttribute("stroke",ratio>=1?"#0ac97f":"#10a37f");}}'
  // 注意：字符串里绝对不能写 // 注释 —— 生成出来的 JS 是一整行，
  // 行注释会把后面所有代码都注释掉，表现为 "Unexpected end of input"。
  // 【坐标字段】Touch 对象只有 clientX/clientY，没有 x/y。
  // 这里曾直接读 t.x/t.y，取到 undefined -> 距离算出 NaN -> paint 的 shown 恒为 false，
  // 真机上表现为"事件都收到了、日志正常，但圆环永远不出现"。
  // 统一走 pos() 归一化，touch 与 pointer 两条分支共用同一套坐标。
  + 'function pos(e){var t=e.touches&&e.touches.length?e.touches[0]:e;'
  + 'return {y:(t.clientY!==undefined?t.clientY:t.pageY),x:(t.clientX!==undefined?t.clientX:t.pageX)};}'
  + 'function onStart(e){'
  + 'if(!e.touches||e.touches.length!==1)return;'
  + 'var p=pos(e);'
  + 'var tgt=e.target;'
  + 'if(tgt&&tgt.closest&&tgt.closest("input,textarea,[contenteditable]:not([contenteditable=false])")){tracking=false;return;}'
  + 'var box=scroller(tgt);'
  + 'if(!atTop(box)){tracking=false;return;}'
  + 'tracking=true;armed=true;dy=0;startY=p.y;startX=p.x;}'
  + 'function onMove(e){'
  + 'if(!tracking||!e.touches||e.touches.length!==1)return;'
  + 'var p=pos(e);'
  + 'var d=p.y-startY,dx=Math.abs(p.x-startX);'
  + 'if(d<=0){dy=0;paint(0);return;}'
  + 'if(d<12)return;'
  // 横向为主 -> 用户在左右滑（例如消息横向滚动/侧栏手势），退出本次判定。
  + 'if(dx>d*1.5){tracking=false;paint(0);return;}'
  + 'dy=Math.min(d,MAX_DY);paint(Math.max(0.02,dy/THRESHOLD));}'
  + 'function onEnd(){'
  + 'if(!tracking){paint(0);return;}'
  + 'tracking=false;'
  + 'var fire=armed&&dy>=THRESHOLD&&Date.now()-lastFire>GAP;'
  + 'armed=false;dy=0;paint(0);'
  + 'if(!fire)return;'
  + 'lastFire=Date.now();'
  + 'try{var b=window.ohosBridge;'
  + 'if(b&&b.onPullRefresh){b.onPullRefresh();}}catch(e){}}'
  // 【必须用 touch，不能用 pointer】
  // 真机实测：页面一开始向下滚动，浏览器就把它当作滚动手势接管，
  // pointer 事件立刻收到 pointercancel，此后 pointermove 全部消失 ——
  // 只收到过一次 move（dy≈39），阈值永远凑不满。
  // touchmove 不同：它属于"已经开始的滚动"，在滚动过程中会持续派发，
  // 所以这里以 touch 为主；pointer 仅作为没有 touch 事件的环境（如 2in1 触控板）的兜底。
  // pos() 已在上面统一声明，这里直接复用，避免同一作用域重复定义。
  + 'function startAt(e,p){'
  + 'var tgt=e.target;'
  + 'if(tgt&&tgt.closest&&tgt.closest("input,textarea,[contenteditable]:not([contenteditable=false])")){tracking=false;return;}'
  + 'var box=scroller(tgt);if(!atTop(box)){tracking=false;return;}'
  + 'tracking=true;armed=true;dy=0;startY=p.y;startX=p.x;}'
  + 'function moveTo(p){'
  + 'if(!tracking)return;'
  + 'var d=p.y-startY,dx=Math.abs(p.x-startX);'
  + 'if(d<=0){dy=0;paint(0);return;}'
  + 'if(d<12)return;'
  + 'if(dx>d*1.5){tracking=false;paint(0);return;}'
  + 'dy=Math.min(d,MAX_DY);paint(Math.max(0.02,dy/THRESHOLD));}'
  + 'function finish(){'
  + 'if(!tracking){paint(0);return;}'
  + 'tracking=false;'
  + 'var fire=armed&&dy>=THRESHOLD&&Date.now()-lastFire>GAP;'
  + 'armed=false;dy=0;paint(0);'
  + 'if(!fire)return;'
  + 'lastFire=Date.now();'
  + 'try{var b=window.ohosBridge;if(b&&b.onPullRefresh){b.onPullRefresh();}}catch(e){}}'
  // touch 为主（滚动过程中持续派发）；没有 touch 事件的环境再用 pointer 兜底。
  + 'var hasTouch="ontouchstart" in window;'
  + 'if(hasTouch||!("PointerEvent" in window)){'
  + 'document.addEventListener("touchstart",onStart,{capture:true,passive:true});'
  + 'document.addEventListener("touchmove",onMove,{capture:true,passive:true});'
  + 'document.addEventListener("touchend",onEnd,{capture:true,passive:true});'
  + 'document.addEventListener("touchcancel",function(){tracking=false;armed=false;dy=0;paint(0);},'
  + '{capture:true,passive:true});}'
  + 'if(!hasTouch&&window.PointerEvent){'
  + 'document.addEventListener("pointerdown",function(e){startAt(e,pos(e));},{capture:true,passive:true});'
  + 'document.addEventListener("pointermove",function(e){moveTo(pos(e));},{capture:true,passive:true});'
  + 'document.addEventListener("pointerup",finish,{capture:true,passive:true});'
  + 'document.addEventListener("pointercancel",function(){tracking=false;armed=false;dy=0;paint(0);},'
  + '{capture:true,passive:true});}'
  + '})();';

/** 触摸设备的 hover/none 两个查询必须互斥；复用原生 MediaQueryList 的变化事件。 */
export const HOVER_FIX_JS: string = '(function(){'
  + 'if(window.__ohosHv)return;window.__ohosHv=1;'
  + 'var mm=window.matchMedia;if(!mm||!mm.call(window,"(pointer: coarse)").matches)return;'
  + 'var wrap=function(q){var fixed=q;if(typeof q==="string")fixed=q'
  + '.replace(/\\(\\s*(?:any-)?hover\\s*:\\s*hover\\s*\\)/gi,"(pointer: fine)")'
  + '.replace(/\\(\\s*(?:any-)?hover\\s*:\\s*none\\s*\\)/gi,"(pointer: coarse)");'
  + 'return mm.call(window,fixed);};'
  + 'Object.defineProperty(window,"matchMedia",{configurable:true,get:function(){return wrap;}});'
  + '})();';
