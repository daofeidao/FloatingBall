//
//  BallRenderer.swift
//
//  球的样子**只在这一个地方画**。
//
//  为什么要这么分：
//    屏幕上的球跑在 root 的 HUD 进程里（ObjC），但「形状 / 颜色 / 自定义图片」
//    是在 App 里设的。如果两边各写一份画图代码，迟早会「预览和实际不一样」。
//    所以：App 用这里的代码画好一张 PNG，写到 BALL_IMAGE_PATH，
//    HUD 那边只做一件事 —— 读文件显示（见 BallRootViewController 的 applyBallStyle）。
//
//  ⚠️ 这里的比例参数（0.57 / 0.075 / 0.035 …）和 scripts/make_icon.py 里的是同一套，
//     改颜色/改比例时**两边都要改**，否则「桌面图标」和「屏幕上的球」会长得不一样。
//     桌面图标固定用「小圆点」那一套。
//

import UIKit

// MARK: - 形状

enum BallShape: String, CaseIterable, Identifiable {
    case dot    = "dot"      // 小圆点：圆 + 细环 + 十字（照系统辅助触控画的）
    case plain  = "plain"    // 纯色：圆 + 细环
    case white  = "white"    // 白点（预设）
    case custom = "custom"   // 自定义图片

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dot:    return "小圆点"
        case .plain:  return "纯色"
        case .white:  return "白点"
        case .custom: return "自定义"
        }
    }

    /// 选择器里的缩略图（自定义图用用户自己那张，没有就用系统图标）
    var thumbnailName: String? {
        switch self {
        case .dot:    return "BallDot"
        case .plain:  return "BallPlain"
        case .white:  return "BallWhite"
        case .custom: return nil
        }
    }

    /// 这一项是不是「预设」：预设的含义是「你画好的那张图」，颜色固定、不受颜色设置影响
    var isPreset: Bool { self == .white }

    var hint: String {
        switch self {
        case .dot:    return "和 iPhone 自带的辅助触控小圆点一样（默认）"
        case .plain:  return "一个干净的圆，想换色就用下面「颜色」"
        case .white:  return "内置预设：不透明的白点，深色壁纸 / 夜里更显眼"
        case .custom: return "用你自己相册里的图片，会自动裁成圆形"
        }
    }
}

// MARK: - 画图

enum BallRenderer {

    /// 画好的球贴图（HUD 读这个文件）。放在 Preferences 目录里，
    /// cfprefsd 只管 .plist，不管 .png，所以放这儿不会被它搅和。
    static let ballImagePath = "/var/mobile/Library/Preferences/com.daofeidao.floatingball.ball.png"

    /// 用户从相册选的原图，留着备用（换颜色时不用重选）
    static let customSourcePath = "/var/mobile/Library/Preferences/com.daofeidao.floatingball.custom.png"

    /// 一个形状的全部比例参数（都以「球直径」为单位）
    private struct Spec {
        let bodyAlpha: CGFloat
        let ringAlpha: CGFloat
        let ringInset: CGFloat
        let ringStroke: CGFloat
        let crossAlpha: CGFloat
        let crossArm: CGFloat
        let crossStroke: CGFloat

        static let zero = Spec(bodyAlpha: 0, ringAlpha: 0, ringInset: 0,
                               ringStroke: 0, crossAlpha: 0, crossArm: 0, crossStroke: 0)
    }

    /// ⚠️ 必须和 scripts/make_icon.py 的 STYLES 保持一致
    private static let specs: [BallShape: Spec] = [
        .dot:   Spec(bodyAlpha: 0.57, ringAlpha: 0.42, ringInset: 0.075, ringStroke: 0.035,
                     crossAlpha: 0.34, crossArm: 0.360, crossStroke: 0.032),
        .plain: Spec(bodyAlpha: 0.55, ringAlpha: 0.38, ringInset: 0.060, ringStroke: 0.040,
                     crossAlpha: 0, crossArm: 0, crossStroke: 0),
        .white: Spec(bodyAlpha: 0.92, ringAlpha: 0.22, ringInset: 0.060, ringStroke: 0.035,
                     crossAlpha: 0, crossArm: 0, crossStroke: 0),
    ]

    /// 画一张球贴图。正方形、圆点满幅（和打包进 App 的那几张 png 同一规矩）
    ///
    /// - Parameters:
    ///   - pixelSize: 像素边长。给多少就是多少像素，**不再乘屏幕倍率**
    static func render(shape: BallShape,
                       color: UIColor,
                       pixelSize: CGFloat,
                       customImage: UIImage? = nil) -> UIImage {

        let side = max(64, pixelSize)
        let size = CGSize(width: side, height: side)
        let rect = CGRect(origin: .zero, size: size)

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = 1          // 见上：pixelSize 已经是像素了

        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            // 自定义图片：裁成圆、按 aspect fill 铺满
            if shape == .custom, let img = customImage {
                UIBezierPath(ovalIn: rect).addClip()
                drawAspectFill(img, in: rect)
                return
            }

            let spec = specs[shape] ?? specs[.dot]!
            let bodyColor = (shape == .white) ? UIColor.white : color
            let ink = contrastingColor(for: bodyColor)

            // 1. 圆底
            bodyColor.withAlphaComponent(spec.bodyAlpha).setFill()
            UIBezierPath(ovalIn: rect).fill()

            // 2. 外圈细环
            let stroke = spec.ringStroke * side
            let inset = spec.ringInset * side + stroke / 2.0
            ink.withAlphaComponent(spec.ringAlpha).setStroke()
            let ring = UIBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset))
            ring.lineWidth = stroke
            ring.stroke()

            // 3. 中间的十字
            if spec.crossAlpha > 0 {
                let arm = spec.crossArm * side
                let thick = spec.crossStroke * side
                let center = CGPoint(x: rect.midX, y: rect.midY)

                ink.withAlphaComponent(spec.crossAlpha).setStroke()
                let cross = UIBezierPath()
                cross.move(to: CGPoint(x: center.x - arm, y: center.y))
                cross.addLine(to: CGPoint(x: center.x + arm, y: center.y))
                cross.move(to: CGPoint(x: center.x, y: center.y - arm))
                cross.addLine(to: CGPoint(x: center.x, y: center.y + arm))
                cross.lineWidth = thick
                cross.lineCapStyle = .butt     // 平头 = 和 make_icon.py 里画的「长条」等价
                cross.stroke()
            }
        }
    }

    /// 环 / 十字要用的「对比色」：身子深就画白，身子浅就画黑。
    /// 这样「颜色」随便选，环都看得见（选白 → 自动变白点那种效果）。
    static func contrastingColor(for color: UIColor) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return .white }
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance > 0.6 ? .black : .white
    }

    private static func drawAspectFill(_ image: UIImage, in rect: CGRect) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(x: rect.midX - drawn.width / 2.0, y: rect.midY - drawn.height / 2.0)
        image.draw(in: CGRect(origin: origin, size: drawn))
    }

    // MARK: - 设置（读到 Swift 侧，画图用）

    static func loadShape() -> BallShape {
        BallShape(rawValue: BallSettings.string("BallShape", default: BallShape.dot.rawValue)) ?? .dot
    }

    static func loadColor() -> UIColor {
        UIColor(hexString: BallSettings.string("BallColor", default: "#000000")) ?? .black
    }

    /// 用户相册里选的那张原图（没选过就是 nil）
    static func loadCustomImage() -> UIImage? {
        guard FileManager.default.fileExists(atPath: customSourcePath) else { return nil }
        return UIImage(contentsOfFile: customSourcePath)
    }

    /// 按当前设置重画球贴图并写到公共路径。
    ///
    /// ⚠️ 固定按 512px 画，**不跟球的大小走**：
    ///    贴图里所有比例都是「相对直径」的，放大靠 HUD 那边拉伸就行；
    ///    而且拖大小滑块时不该每次都重画一次 PNG（缩略图会卡）。
    /// - Returns: 出错原因；nil = 成功
    static func regenerate() -> String? {
        let shape = loadShape()
        let color = loadColor()
        let custom = (shape == .custom) ? loadCustomImage() : nil

        let image = render(shape: shape, color: color, pixelSize: 512, customImage: custom)
        guard let data = image.pngData() else { return "PNG 编码失败" }
        do {
            try data.write(to: URL(fileURLWithPath: ballImagePath))
            return nil
        } catch {
            return "写不进 \(ballImagePath)（\(error.localizedDescription)）"
        }
    }

    /// 把用户选的图存下来（原图留着，换颜色时不用重选）
    static func saveCustomImage(_ image: UIImage) -> Bool {
        guard let data = image.pngData() else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: customSourcePath))
            return true
        } catch {
            return false
        }
    }
}

// MARK: - 颜色 <-> 十六进制

extension UIColor {

    /// "#RRGGBB" / "RRGGBB"
    convenience init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(red:   CGFloat((value >> 16) & 0xFF) / 255.0,
                  green: CGFloat((value >> 8) & 0xFF) / 255.0,
                  blue:  CGFloat(value & 0xFF) / 255.0,
                  alpha: 1.0)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return "#000000" }
        // ⚠️ 传 UInt32：%X 要的是 32 位无符号，别塞 Int（64 位），
        //    虽然实践上也对，但类型对上才不会有平台差异。
        return String(format: "#%02X%02X%02X",
                      UInt32((r * 255).rounded()),
                      UInt32((g * 255).rounded()),
                      UInt32((b * 255).rounded()))
    }
}
