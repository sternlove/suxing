/**
 * 桌面小组件（2x2）：苏兴当前状态。
 *
 * 数据流：UIAbility 写沙箱文件 → EntryFormAbility 读文件并 createFormBindingData
 *        → 本页面用 @LocalStorageProp 接。卡片在独立进程，不能直接引用 Index 的状态。
 */
let storage: LocalStorage = new LocalStorage();

@Entry(storage)
@Component
struct Card01 {
  @LocalStorageProp('face') face: string = '😐';
  @LocalStorageProp('snippet') snippet: string = '还没聊过';
  @LocalStorageProp('status') status: string = '💭 主动搭话开启';

  build() {
    Column({ space: 6 }) {
      Row() {
        Text('苏兴')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#E8E8F0')
        Blank()
        Text(this.face)
          .fontSize(20)
      }
      .width('100%')

      Text(this.snippet)
        .fontSize(12)
        .fontColor('#B8B8C8')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .layoutWeight(1)
        .textAlign(TextAlign.Start)

      Text(this.status)
        .fontSize(10)
        .fontColor('#7C7C8C')
        .maxLines(1)
        .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor('#1E1E24')
    .borderRadius(16)
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Start)
  }
}
