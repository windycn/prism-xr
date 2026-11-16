import Foundation
@main enum MirrorRegression {
 static func main() throws {
  let legacy = Data(#"{"targets":{},"refresh":60,"mode":"lookAround","field":62,"mirrorsMacDesktop":false}"#.utf8)
  let preferences = try JSONDecoder().decode(LayoutPreferences.self, from: legacy)
  for preset in ScreenLayout.allCases {
   let layout = WorkspaceLayout.preset(preset)
   let mirror = layout.mirroredPanelID(using: preferences)
   precondition(mirror != nil && layout.panels.filter { $0.id == mirror }.count == 1)
   var chosen = preferences;chosen.mirrorScreenID = layout.configurableScreens.last!.id
   precondition(layout.mirroredPanelID(using: chosen) == layout.configurableScreens.last!.panel.id)
   chosen.mirrorScreenID = "deleted-screen"
   precondition(layout.mirroredPanelID(using: chosen) == layout.panels.first(where: \.primary)!.id)
  }
  var unequalTargets = preferences
  unequalTargets.targets["0"] = ScreenTarget(width:1600,height:1200,hiDPI:true)
  for preset in [ScreenLayout.triple, .stacked] {
   let panels = WorkspaceLayout.preset(preset).panels(using:unequalTargets)
   precondition(panels.allSatisfy { abs($0.width - panels[0].width) < 1e-9 && abs($0.height - panels[0].height) < 1e-9 })
  }
  var custom = CustomLayout(name: "Mirror regression")
  custom.screens.append(CustomScreen());custom.primaryID = custom.screens[1].id
  let layout = WorkspaceLayout.custom(custom)
  precondition(layout.mirroredPanelID(using: preferences) == 1)
  print("PASS nine layouts and custom layout always contain exactly one Mac mirror; selectable source and legacy migration")
 }
}
