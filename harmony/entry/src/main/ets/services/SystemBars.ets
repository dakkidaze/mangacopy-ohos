/**
 * 系统栏（状态栏 / 导航指示条）统一控制。
 *
 * 冷启动（Index）与设置页「立即应用」共用这一份实现，防止两条路径再次漂移——
 * 曾出过的事故：设置页路径用旧整组接口 setWindowSystemBarEnable(['navigation'])，
 * 运行中切换「隐藏状态栏」会把小白条（导航指示条）一并弄没（冷启动路径已修、设置页没跟上）。
 *
 * 规则：只用逐条 API；两条调用各自独立 try；小白条那条失败不影响状态栏、也不退回旧接口；
 * 仅当状态栏那条本身失败时才退回旧的整组写法（老设备兼容路径）。
 */
import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

export async function applyStatusBarVisibility(context: common.UIAbilityContext, hidden: boolean): Promise<void> {
  const mainWindow = await window.getLastWindow(context);
  let statusOk = false;
  try {
    await mainWindow.setSpecificSystemBarEnabled('status', !hidden);
    statusOk = true;
  } catch (error) {
    hilog.info(0x0000, 'Collector', '%{public}s', '系统栏：setSpecific(status) 失败，退回旧接口');
  }
  if (!statusOk) {
    // 仅当状态栏那条本身失败时才退回旧写法（老设备兼容路径）
    await mainWindow.setWindowSystemBarEnable(hidden ? ['navigation'] : ['status', 'navigation']);
  }
  try {
    // 设置行承诺「导航栏保持可用」：显式确保小白条可见；此条失败不影响状态栏、也不退回旧接口
    await mainWindow.setSpecificSystemBarEnabled('navigationIndicator', true);
  } catch (error) {
    hilog.info(0x0000, 'Collector', '%{public}s', '系统栏：navigationIndicator 设置失败（忽略，交系统默认）');
  }
}
