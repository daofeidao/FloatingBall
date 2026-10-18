//
//  UserDefaultsExtensions.swift
//
//
//  Created by lemin on 12/8/23.
//

import Foundation
import UIKit

extension UserDefaults {
    // MARK: Managing the Data
    func loadUserDefaults(forPath path: String) -> [String: Any] {
        do {
            let plistData: Data = try Data(contentsOf: URL(fileURLWithPath: path))
            if let dict: [String: Any] = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] {
                return dict
            }
        } catch {
            // file doesn't exist
        }
        return [:]
    }

    /// ⚠️ 0.1.19：写之前必须能区分「**读失败**」和「**本来就没有**」。
    ///
    /// 原来的 `setValue` 无条件 `loadUserDefaults` 然后写回。而 `loadUserDefaults`
    /// 的 catch 把「文件不存在」「权限不足」「XML 读到一半」三种情况**统统**返回 `[:]`：
    ///   · 读到半截 XML（下面这个文件被 App(uid 501) 和球(root) **同时**读写，
    ///     而原来是非原子写）→ [:] → dict[key]=value → **把用户所有设置抹成只剩这一个键**，
    ///     而且没有任何提示，用户的形状/颜色/大小/快捷列表/手势绑定全没了。
    /// 现在读失败就直接放弃写入。
    func setValue(_ value: Any?, forKey key: String, forPath path: String) {
        var dict: [String: Any] = [:]

        // 文件压根不存在 = 第一次设置，这是正常路径，当空字典处理。
        if FileManager.default.fileExists(atPath: path) {
            do {
                let plistData = try Data(contentsOf: URL(fileURLWithPath: path))
                dict = (try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any]) ?? [:]
            } catch {
                print("[FloatingBall] ⚠️ 读 \(path) 失败（\(error.localizedDescription)）—— 放弃这次写入，不拿空字典覆盖用户设置")
                return
            }
        }

        dict[key] = value
        do {
            let newData: Data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            // ⚠️ 必须 .atomic：这个 plist 被 App 和球进程同时读写，
            //    非原子写是「截断 → 写」，对面正好在读就会拿到半截 XML。
            //    HUD 侧（BallRootViewController.savePrefs）用的就是 atomically:YES，两边要对齐。
            try newData.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            print(error.localizedDescription)
        }
    }
    
    func removeObject(forKey defaultName: String, forPath path: String) {
        setValue(nil, forKey: defaultName, forPath: path)
    }
    
    func deleteUserDefaults(forPath path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }
    
    
    // MARK: Specific Type Functions
    
    // string
    func string(forKey defaultName: String, forPath path: String) -> String? {
        let dict = loadUserDefaults(forPath: path)
        return dict[defaultName] as? String
    }
    
    // double
    func double(forKey defaultName: String, forPath path: String) -> Double {
        let dict = loadUserDefaults(forPath: path)
        return dict[defaultName] as? Double ?? 0
    }
    
    // integer
    func integer(forKey defaultName: String, forPath path: String) -> Int {
        let dict = loadUserDefaults(forPath: path)
        return dict[defaultName] as? Int ?? 0
    }
    
    // bool
    func bool(forKey defaultName: String, forPath path: String) -> Bool {
        let dict = loadUserDefaults(forPath: path)
        return dict[defaultName] as? Bool ?? false
    }
    
    // array
    func array(forKey defaultName: String, forPath path: String) -> [Any]? {
        let dict = loadUserDefaults(forPath: path)
        return dict[defaultName] as? [Any]
    }
}
