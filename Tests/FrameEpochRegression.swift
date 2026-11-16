import CoreVideo
import Foundation
@main enum FrameEpochRegression {
 static func main() {
  func buffer(_ width:Int)->CVPixelBuffer {
   var value:CVPixelBuffer?
   precondition(CVPixelBufferCreate(kCFAllocatorDefault,width,4,kCVPixelFormatType_32BGRA,nil,&value)==kCVReturnSuccess)
   return value!
  }
  let store=SpatialFrameStore(), a=buffer(4), b=buffer(8)
  let old=store.token();store.store(a,panel:0,generation:old)
  let oldSequence=store.snapshot().frames[0]!.sequence
  store.reset();let fresh=store.token();precondition(fresh != old)
  let oldFrame = SpatialCapturedFrame(buffer:a,sequence:0,receivedAt:0)
  DispatchQueue.concurrentPerform(iterations:1000) { _ in store.store(oldFrame.buffer,panel:0,generation:old) }
  precondition(store.snapshot().frames.isEmpty,"late old source frame accepted")
  store.store(b,panel:0,generation:fresh)
  let snapshot=store.snapshot()
  precondition(snapshot.generation==fresh && snapshot.frames[0]!.sequence>oldSequence)
  precondition(CVPixelBufferGetWidth(snapshot.frames[0]!.buffer)==8)
  store.rendered(at:1,size:CGSize(width:999,height:999),generation:old)
  precondition(store.readMetrics().width==0,"stale presentation callback accepted")
  store.rendered(at:2,size:CGSize(width:160,height:90),generation:fresh)
  store.rendered(at:999,size:CGSize(width:999,height:999),generation:old)
  precondition(store.readMetrics().width==160)
  print("PASS atomic frame epochs: 1000 late callbacks rejected; old presentation metrics cannot overwrite current session")
 }
}
