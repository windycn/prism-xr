import AppKit
import MetalKit
import Observation
@MainActor @Observable final class SpatialDesktop { let frameStore = SpatialFrameStore() }
@main enum MetalDriverFPS {
 @MainActor static func main() {
  let app = NSApplication.shared;app.setActivationPolicy(.accessory)
  let activity = ProcessInfo.processInfo.beginActivity(options:[.userInitiatedAllowingIdleSystemSleep,.latencyCritical],reason:"Spatial renderer regression")
  let store=SpatialFrameStore();var buffer:CVPixelBuffer?
  let attrs = [kCVPixelBufferIOSurfacePropertiesKey:[:],kCVPixelBufferMetalCompatibilityKey:true] as CFDictionary
  precondition(CVPixelBufferCreate(kCFAllocatorDefault,320,180,kCVPixelFormatType_32BGRA,attrs,&buffer)==kCVReturnSuccess)
  let pixel=buffer!;CVPixelBufferLockBaseAddress(pixel,[])
  memset(CVPixelBufferGetBaseAddress(pixel),128,CVPixelBufferGetBytesPerRow(pixel)*180)
  CVPixelBufferUnlockBaseAddress(pixel,[]);store.store(pixel,panel:0,generation:store.token())
  let renderer=SpatialMetalRenderer(frames:store);renderer.configure(layout:.preset(.single),preferences:LayoutPreferences(),input:nil,lockHorizon:true)
  let view=DesktopMetalView(renderer:renderer);view.frame=CGRect(x:0,y:0,width:320,height:180)
  let window=NSWindow(contentRect:view.frame,styleMask:.borderless,backing:.buffered,defer:false)
  window.isReleasedWhenClosed=false;window.ignoresMouseEvents=true;window.contentView=view;window.orderFrontRegardless()
  DispatchQueue.main.asyncAfter(deadline:.now()+3) {
   let m=store.readMetrics();print("DISPLAY LINK presentedFPS=\(m.fps), maxGapMS=\(m.maxGapMS), output=\(m.width)x\(m.height), error=\(m.error ?? "none")")
   view.stopRendering();window.close();ProcessInfo.processInfo.endActivity(activity)
   exit(m.error == nil && m.fps > 45 ? 0 : 1)
  }
  app.run()
 }
}
