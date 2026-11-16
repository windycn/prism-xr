import Foundation
@main enum CursorRegression {
 static func main() {
  let main = CursorScreen(displayID: 1, bounds: CGRect(x:0,y:0,width:1470,height:956), sceneBounds:CGRect(x:-0.27,y:-0.233,width:0.54,height:0.304))
  let left = CursorScreen(displayID: 2,bounds:CGRect(x:-1660,y:956,width:1600,height:900),sceneBounds:CGRect(x:-0.3645,y:0.0775,width:0.223,height:0.125))
  let center = CursorScreen(displayID: 3,bounds:CGRect(x:-60,y:956,width:1600,height:900),sceneBounds:CGRect(x:-0.1115,y:0.0775,width:0.223,height:0.125))
  let right = CursorScreen(displayID: 4,bounds:CGRect(x:1540,y:956,width:1600,height:900),sceneBounds:CGRect(x:0.1415,y:0.0775,width:0.223,height:0.125))
  let screens = [main,left,center,right]
  let l = SpatialCursorRouter.transfer(previous:CGPoint(x:150,y:950),current:CGPoint(x:150,y:960),screens:screens)
  let r = SpatialCursorRouter.transfer(previous:CGPoint(x:1300,y:950),current:CGPoint(x:1300,y:960),screens:screens)
  precondition(l?.displayID == 2, "bottom-left must enter left auxiliary")
  precondition(r?.displayID == 4, "bottom-right must enter right auxiliary")
  let natural = SpatialCursorRouter.transfer(previous:CGPoint(x:735,y:950),current:CGPoint(x:735,y:960),screens:screens)
  precondition(natural == nil, "natural center crossing must be kept")
  let topLeft = CursorScreen(displayID: 5,bounds:CGRect(x:0,y:0,width:100,height:100),sceneBounds:CGRect(x:-1,y:-1,width:1,height:1))
  let topRight = CursorScreen(displayID: 6,bounds:CGRect(x:500,y:0,width:100,height:100),sceneBounds:CGRect(x:0,y:-1,width:1,height:1))
  let bottomLeft = CursorScreen(displayID: 7,bounds:CGRect(x:0,y:500,width:100,height:100),sceneBounds:CGRect(x:-1,y:0,width:1,height:1))
  let grid = [topLeft,topRight,bottomLeft]
  precondition(SpatialCursorRouter.transfer(previous:CGPoint(x:90,y:50),current:CGPoint(x:99,y:50),screens:grid)?.displayID == 6)
  precondition(SpatialCursorRouter.transfer(previous:CGPoint(x:50,y:90),current:CGPoint(x:50,y:99),screens:grid)?.displayID == 7)
  let output = CGRect(x:4000,y:0,width:1920,height:1080)
  let safe = CGPoint(x:735,y:500)
  precondition(SpatialCursorRouter.fenceOutput(point:CGPoint(x:4100,y:500),output:output,screens:screens,lastSafe:safe) == safe)
  let fallback = SpatialCursorRouter.fenceOutput(point:CGPoint(x:4100,y:500),output:output,screens:screens,lastSafe:CGPoint(x:99999,y:99999))
  precondition(fallback != nil && screens.contains { $0.bounds.contains(fallback!) })
  precondition(SpatialCursorRouter.fenceOutput(point:CGPoint(x:735,y:500),output:output,screens:screens,lastSafe:safe) == nil)
  print("PASS output pointer fence: safe return, expired source fallback, working screens unaffected")
  print("PASS mouse routing: mirrored main -> left/center/right auxiliaries; 2x2 horizontal/vertical")
 }
}
