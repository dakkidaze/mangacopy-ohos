/**
 * Index.ets — 单一 @Entry 页面（工程约定：不引入 Navigation/router，
 * 后续场景全部走「内部路由枚举 + Stack 条件渲染」，参见 harmony/README.md）。
 */
@Entry
@Component
struct Index {
  @State readyText: string = '骨架就绪：ArkTS 工程已可构建 HAP';

  build() {
    Column() {
      Image($r('app.media.app_icon'))
        .width(96)
        .height(96)
        .margin({ top: 160, bottom: 24 })

      Text('MangaCopyOHOS')
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.primary_text'))

      Text(this.readyText)
        .fontSize(16)
        .fontColor($r('app.color.secondary_text'))
        .margin({ top: 12 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .alignItems(HorizontalAlign.Center)
  }
}
