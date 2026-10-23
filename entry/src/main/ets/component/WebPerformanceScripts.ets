/**
 * 侧栏与长会话的渲染减负。
 *
 * 思路：先量到元素的真实高度，再用 content-visibility:auto 让屏幕外的部分跳过
 * 布局/绘制，同时用 contain-intrinsic-block-size 保留占位，滚动条长度不变。
 *
 * 和"直接隐藏"的本质区别：
 *   · DOM 全部保留 —— 网页自己的 querySelector、React 状态、事件委托都不受影响；
 *   · 高度保留 —— 滚动位置和锚定不跳；
 *   · :not(:focus-within) —— 正在编辑的元素永远不被跳过，输入不会掉焦点。
 *
 * 侧栏为什么单独处理：
 *   ChatGPT 侧栏在会话多的时候是长列表，且每行都带 hover 菜单、拖拽排序句柄、
 *   未读徽标等一堆节点。它不在 <main> 里，所以原实现那条 main 选择器覆盖不到，
 *   只靠 .sidebar-item[data-sidebar-cycle-item] 一条兜底 —— 网页改版就会漏。
 *   这里改成按"结构特征"匹配（nav / aside / [role=navigation] 下的 listitem），
 *   不再依赖某个具体 class 名。
 */

/** content-visibility 与容器查询的可用性判断做成独立常量，便于两处脚本复用。 */
const SUPPORT_GUARD: string =
  'if(!window.ResizeObserver||!window.MutationObserver||!window.CSS||'
  + '!CSS.supports("content-visibility","auto")||'
  + '!CSS.supports("contain-intrinsic-block-size","auto 1px"))return;';

export const MEASURED_RENDER_JS: string = '(function(){'
  + 'if(window.__ohosMeasuredRender)return;' + SUPPORT_GUARD
  + 'var d=document,mark="data-ohos-render-skip";'
  // 选择器分两组：消息区沿用原来的精确匹配；侧栏改为结构特征匹配，抗改版。
  + 'var msgSel="main article,main [data-message-id],main [data-chatgpt-search-unit-key]";'
  + 'var sideSel="nav [role=listitem],nav li,aside [role=listitem],aside li,'
  + '[role=navigation] [role=listitem],[role=navigation] li,'
  + '.sidebar-item[data-sidebar-cycle-item],[data-sidebar-cycle-item],'
  + '[aria-roledescription=sortable],[data-pinned-content-tab-drop-key]";'
  + 'var selector=msgSel+","+sideSel;'
  + 'var host=d.head||d.documentElement;if(!host)return;window.__ohosMeasuredRender=1;'
  + 'var style=d.createElement("style");style.id="ohos-measured-render";'
  // contain-intrinsic-size 用 auto，浏览器会记住上次真实高度，回滚时不会跳。
  //
  // 【为什么还要一条"不等测量"的预置规则】
  // 只靠下面那条 =ready 规则时，属性要等 ResizeObserver 回调（下一帧）才加上，
  // 而侧栏展开的首帧布局早就发生了 —— 首帧一点优化都吃不到。
  // 真机实测：点侧栏按钮，0.3s 时侧栏框架已出、但项目下的会话条目全是空白占位，
  // 1.5s 才铺满，用户感知就是"点一下要两三秒"。
  //
  // 侧栏行高度基本一致（单行约 32~40px），所以可以直接给一个 40px 兜底：
  // content-visibility:auto 只跳过**屏幕外**的元素，屏幕内的行仍然照常渲染，
  // 视觉上没有变化；滚动条长度会因为估高略有偏差，等 ResizeObserver 量到真实高度后自动修正。
  //
  // 注意这条**只对侧栏**生效，不能套到消息区：一条消息可能 200px 也可能 2000px，
  // 用 40px 兜底会让长会话的滚动条严重失真、滚动位置乱跳。
  + 'style.textContent='
  + '"nav [role=listitem],aside [role=listitem],[role=navigation] [role=listitem],'
  + '[aria-roledescription=sortable],[data-sidebar-cycle-item],[data-pinned-content-tab-drop-key]{'
  + 'content-visibility:auto;contain-intrinsic-block-size:auto 40px;}'
  + '[data-ohos-render-skip=ready]:not(:focus-within){'
  + 'content-visibility:auto;contain-intrinsic-block-size:auto var(--ohos-block-size);}";'
  + 'host.appendChild(style);'
  + 'var sizes=new WeakMap();'
  // 高度只有在真正变化时才写变量：ResizeObserver 在滚动中也会触发，
  // 无条件写 style 会让每帧都有一次样式失效。
  + 'var resize=new ResizeObserver(function(entries){'
  + 'for(var i=0;i<entries.length;i++){var e=entries[i],el=e.target;'
  + 'if(!el.isConnected){resize.unobserve(el);sizes.delete(el);el.removeAttribute(mark);continue;}'
  + 'var h=e.contentRect.height;if(h<=0||sizes.get(el)===h)continue;'
  + 'sizes.set(el,h);el.style.setProperty("--ohos-block-size",h+"px");'
  + "if(el.getAttribute(mark)!==\"ready\")el.setAttribute(mark,\"ready\");}});"
  + 'function enroll(el){if(el.hasAttribute(mark))return;'
  + 'if(el.parentElement&&el.parentElement.closest(selector))return;'
  + 'el.setAttribute(mark,"pending");resize.observe(el);}'
  + 'function scan(root){if(root.nodeType!==1)return;'
  + 'if(root.matches(selector)){enroll(root);return;}'
  // 流式回复内部新增的段落不遍历；外层消息已由 ResizeObserver 跟踪。
  + 'if(root.parentElement&&root.parentElement.closest(selector))return;'
  + 'var list=root.querySelectorAll(selector);for(var i=0;i<list.length;i++)enroll(list[i]);}'
  + 'function forget(root){if(root.nodeType!==1||root.isConnected)return;'
  + 'function drop(el){resize.unobserve(el);sizes.delete(el);'
  + 'el.removeAttribute(mark);el.style.removeProperty("--ohos-block-size");}'
  + 'if(root.hasAttribute(mark))drop(root);'
  + 'var list=root.querySelectorAll("[data-ohos-render-skip]");'
  + 'for(var i=0;i<list.length;i++)drop(list[i]);}'
  // 只观察 childList：属性变化（滚动中高频发生）不需要惊动这里。
  //
  // 【按帧批量处理】原实现是"每来一条 mutation 就地对新增子树跑一次 querySelectorAll"。
  // 流式回复时 React 每帧都会新增若干段落，等于每帧都要遍历一次子树 ——
  // 主线程被这些扫描切碎，表现为滚动和打字都发涩。改为把新增节点攒进队列，
  // 每帧最多处理一帧的量；一帧内新增 50 个节点也只付一次调度开销。
  + 'var queue=[],scheduled=0,removed=[];'
  + 'function flush(){scheduled=0;'
  + 'if(removed.length){for(var r=0;r<removed.length;r++)forget(removed[r]);removed.length=0;}'
  + 'if(!queue.length)return;'
  + 'var batch=queue;queue=[];'
  + 'for(var i=0;i<batch.length;i++){try{scan(batch[i]);}catch(e){}}}'
  + 'function schedule(){if(scheduled)return;scheduled=1;'
  + 'if(window.requestAnimationFrame){requestAnimationFrame(flush);}else{setTimeout(flush,16);}}'
  + 'var mutations=new MutationObserver(function(records){for(var i=0;i<records.length;i++){'
  + 'var r=records[i],j;for(j=0;j<r.removedNodes.length;j++)removed.push(r.removedNodes[j]);'
  + 'for(j=0;j<r.addedNodes.length;j++)queue.push(r.addedNodes[j]);}'
  + 'schedule();});'
  + 'mutations.observe(d.documentElement,{childList:true,subtree:true});scan(d.documentElement);'
  + '})();';

/**
 * 滚动期间的额外减负。
 *
 * 解决的问题：长列表滚动时，网页自己挂在 scroll 上的监听（无限加载、回到顶部按钮、
 * 侧栏高亮同步）会在每一帧都跑一次，和合成线程抢主线程。这里做两件事：
 *
 *   1) 把页面后续注册的 scroll 监听统一改成 passive。
 *      scroll 事件本身不可取消（规范里它就是 non-cancelable），所以加 passive
 *      对网页逻辑零影响 —— 这是唯一的"白拿"优化。
 *      【为什么不顺手把 touchmove / wheel 也改成 passive】这两类事件是**可取消**的，
 *      网页常用 preventDefault 拦截（例如阻止滚动链、禁用双指缩放、自定义下拉）。
 *      强行 passive 会让那些 preventDefault 静默失效，属于改行为，不做。
 *      【覆盖范围的诚实说明】documentEnd 注入时，页面在更早阶段注册的监听已经注册完了，
 *      这里只能影响之后注册的那部分。仍有价值：ChatGPT 是 SPA，会话列表、
 *      滚动容器大多是挂载后才绑定监听，正好落在注入点之后。
 *   2) 在滚动进行中给 <html> 加一个标记类，配合 CSS 冻结非必要的过渡/动画。
 *      滚动结束后 120ms 移除，属于"滚动时不画、停下再画"的常见做法。
 *
 * 注意：不改任何点击/长按行为，手势屏蔽仍由 ArkTS 侧的 onGestureRecognizerJudgeBegin 负责。
 */
export const SCROLL_PERF_JS: string = '(function(){'
  + 'if(window.__ohosScrollPerf)return;window.__ohosScrollPerf=1;'
  + 'var d=document;'
  // 1) 仅 scroll 监听降级为 passive（见上方说明）。
  + 'try{'
  + 'var orig=EventTarget.prototype.addEventListener;'
  + 'EventTarget.prototype.addEventListener=function(type,fn,opts){'
  + 'if(type==="scroll"){'
  + 'if(opts===undefined||opts===null){opts={passive:true};}'
  + 'else if(typeof opts==="object"&&opts.passive===undefined){'
  + 'opts=Object.assign({},opts,{passive:true});}}'
  + 'return orig.call(this,type,fn,opts);};}catch(e0){}'
  // 2) 滚动期间只暂停"无限循环"动画（转圈、脉冲），一次性动画和 transition 不动。
  //    直接写 * 会连打字光标、进度条都停掉，属于过度优化。
  + 'var host=d.documentElement,timer=0;'
  + 'var css="html[data-ohos-scrolling] [class*=animate-spin],"'
  + '+"html[data-ohos-scrolling] [class*=animate-pulse],"'
  + '+"html[data-ohos-scrolling] [class*=animate-bounce]{animation-play-state:paused!important;}";'
  + 'var style=d.getElementById("ohos-scroll-perf");'
  + 'if(!style){style=d.createElement("style");style.id="ohos-scroll-perf";'
  + 'style.textContent=css;(d.head||host).appendChild(style);}'
  + 'else{style.textContent=css;}'
  + 'function end(){if(timer){clearTimeout(timer);timer=0;}host.removeAttribute("data-ohos-scrolling");}'
  + 'function begin(){if(timer){clearTimeout(timer);}'
  + 'if(!host.hasAttribute("data-ohos-scrolling"))host.setAttribute("data-ohos-scrolling","1");'
  + 'timer=setTimeout(end,120);}'
  // 用 capture 在最外层收滚动事件，不依赖具体滚动容器在哪。
  + 'd.addEventListener("scroll",begin,{capture:true,passive:true});'
  + '})();';

/**
 * 侧栏滚动锚定修正。
 *
 * 侧栏用 content-visibility 跳过屏幕外行之后，个别浏览器版本会出现
 * "拖动滚动条时位置回弹"。这里在侧栏容器上启用 overscroll-behavior:contain，
 * 阻止滚动链传到外层（外层是 Web 组件本身，滚到头会把整个页面一起拽）。
 * 纯 CSS，不碰 DOM 结构。
 */
export const SIDEBAR_SCROLL_CSS: string =
  'nav,aside,[role="navigation"]{overscroll-behavior:contain;}'
  + '.sidebar-item[data-sidebar-cycle-item],[data-sidebar-cycle-item]{'
  + 'overscroll-behavior:contain;overscroll-behavior-y:contain;}';
