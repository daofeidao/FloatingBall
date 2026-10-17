//
//  BallInterface.swift
//
//  ObjC 侧（MainApplicationDelegate.mm）通过它拿到 App 的主界面。
//

import UIKit
import SwiftUI

@objc class BallInterface: NSObject {
    @objc func createUI() -> UIViewController {
        // 每次 App 启动就按当前设置重画一遍球贴图：
        //   - 第一次装完、还没人动过外观设置时，HUD 那边也有图可读（不用退回包里那张默认图）
        //   - 以后改了画图比例，升级后也会自动跟着更新
        if let error = BallRenderer.regenerate() {
            print("[FloatingBall] 启动时重画球贴图失败：\(error)")
        }
        return UIHostingController(rootView: RootView())
    }
}
