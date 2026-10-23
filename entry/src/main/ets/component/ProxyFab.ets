/**
 * 右侧代理浮窗。
 *
 * ===========================================================================
 * 交互规格
 * ===========================================================================
 *   收起态：贴右边缘，只露窄条 + 状态圆点
 *   点一下：横向展开显示状态（**2 秒无操作自动缩回**）
 *   展开后再点：进入代理设置页（进页前先收起）
 *   **上下拖动**：按住浮窗上下拖，把它挪到屏幕任意高度
 *
 * 【为什么是 2 秒】
 * 浮窗叠在网页上，长期展开会挡住右侧内容。用户展开通常只想瞟一眼状态。
 * 拖动过程中会暂停计时，否则拖到一半自己缩回去会很突兀。
 *
 * 【拖动实现】
 * 用 PanGesture 监听垂直位移，把 offsetY 累加到 fabTop。
 * 边界限制：顶部 >= 90vp（避开顶栏按钮区）。
 * 位置用 .position() 绝对定位，不参与 Stack 的常规布局。
 */

import { ProxyState } from '../mihomo/ProxyManager';

@Component
export struct ProxyFab {
  @Prop proxyState: ProxyState = ProxyState.IDLE;
  @Prop isDark: boolean = false;
  onOpenSettings: () => void = () => {};

  @State private expanded: boolean = false;
  /** 浮窗距顶部的距离（vp），可被拖动改变 */
  @State private fabTop: number = 150;

  private autoCollapseTimer: number = 0;
  /** 自动收回延时：2 秒 */
  private static readonly AUTO_COLLAPSE_MS: number = 2000;
  private dragStartTop: number = 0;
  private dragging: boolean = false;

  aboutToDisappear(): void {
    this.clearTimer();
  }

  private clearTimer(): void {
    if (this.autoCollapseTimer !== 0) {
      clearTimeout(this.autoCollapseTimer);
      this.autoCollapseTimer = 0;
    }
  }

  private startAutoCollapse(): void {
    this.clearTimer();
    this.autoCollapseTimer = setTimeout(() => {
      this.autoCollapseTimer = 0;
      this.expanded = false;
    }, ProxyFab.AUTO_COLLAPSE_MS);
  }

  collapse(): void {
    this.clearTimer();
    this.expanded = false;
  }

  // ---------- 主题 ----------
  private fabAccent(): string {
    if (this.proxyState === ProxyState.RUNNING) {
      return '#22C55E';
    }
    if (this.proxyState === ProxyState.STARTING || this.proxyState === ProxyState.STOPPING) {
      return '#F59E0B';
    }
    if (this.proxyState === ProxyState.ERROR) {
      return '#EF4444';
    }
    return '#8E8E93';
  }
  private fabBg(): string {
    return this.isDark ? '#2C2C2E' : '#FFFFFF';
  }

  private fabText(): string {
    return this.isDark ? '#F5F5F7' : '#111827';
  }
  private fabSubText(): string {
    return this.isDark ? '#98989F' : '#6B7280';
  }

  private fabStateText(): string {
    if (this.proxyState === ProxyState.RUNNING) {
      return '已开启';
    }
    if (this.proxyState === ProxyState.STARTING) {
      return '开启中';
    }
    if (this.proxyState === ProxyState.STOPPING) {
      return '关闭中';
    }
    if (this.proxyState === ProxyState.ERROR) {
      return '出错';
    }
    return '未开启';
  }

  build() {
    Row() {
      // 左边缘状态色带
      Column()
        .width(3)
        .height('100%')
        .backgroundColor(this.fabAccent())
        .borderRadius({ topLeft: 9, bottomLeft: 9 })

      // 状态圆点
      Stack() {
        if (this.proxyState === ProxyState.RUNNING) {
          Circle().width(18).height(18).fill(this.fabAccent()).opacity(0.18)
        }
        Circle().width(7).height(7).fill(this.fabAccent())
      }
      .width(22)
      .height('100%')

      // 展开态文案
      if (this.expanded) {
        Column() {
          Text(this.fabStateText())
            .fontSize(10)
            .fontColor(this.fabSubText())
            .maxLines(1)
          Text('设置')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.fabText())
            .margin({ top: 1 })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Start)
        .padding({ right: 8 })
      }
    }
    .width(this.expanded ? 74 : 25)
    .height(this.expanded ? 46 : 40)
    .backgroundColor(this.fabBg())
    .borderRadius({ topLeft: 9, bottomLeft: 9, topRight: 0, bottomRight: 0 })
    // 【定位方式说明（连续踩坑记录）】
    // 第 1 版：.position({x:'100%'}) + .translate({x:'-100%'})  -> 浮窗被推出屏幕，完全看不见
    // 第 2 版：只靠父级 Stack 的 TopEnd 对齐 + margin.top      -> 能看见，但右半边被裁掉、点击不准
    // 第 3 版（当前）：margin.top 控制垂直位置 + 父级 Stack TopEnd 对齐控制右侧。
    //
    // 【关键的裁切问题】父级 Stack 若没有 clip(false)，子组件超出边界会被裁剪。
    // 之前右半被切就是这个原因 —— 浮窗贴在右边缘，边框/阴影有 1vp 延伸。
    // 现在让 Index.ets 里的 Stack 显式设置 .clip(false)，并把浮窗宽度收窄到可见范围内。
    .margin({ top: this.fabTop })
    .animation({ duration: 200, curve: Curve.EaseOut })
    // ---- 上下拖动 ----
    .gesture(
      PanGesture({ direction: PanDirection.Vertical, distance: 5 })
        .onActionStart(() => {
          this.dragging = true;
          this.dragStartTop = this.fabTop;
          // 拖动期间暂停自动缩回
          this.clearTimer();
        })
        .onActionUpdate((event: GestureEvent) => {
          if (!this.dragging) {
            return;
          }
          let next: number = this.dragStartTop + event.offsetY;
          // 顶部边界：避开顶栏按钮区
          if (next < 90) {
            next = 90;
          }
          this.fabTop = next;
        })
        .onActionEnd(() => {
          this.dragging = false;
          if (this.expanded) {
            this.startAutoCollapse();
          }
        })
    )
    .onClick(() => {
      if (!this.expanded) {
        this.expanded = true;
        this.startAutoCollapse();
      } else {
        this.collapse();
        this.onOpenSettings();
      }
    })
  }
}
