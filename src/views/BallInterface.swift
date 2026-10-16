//
//  BallInterface.swift
//
//  ObjC 侧（MainApplicationDelegate.mm）通过它拿到 App 的主界面。
//

import UIKit
import SwiftUI

@objc class BallInterface: NSObject {
    @objc func createUI() -> UIViewController {
        return UIHostingController(rootView: RootView())
    }
}
