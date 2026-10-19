//
//  IconCropView.swift
//
//  自定义图标的「选一块」页面（0.1.38，用户 2026-10-20 要求）。
//
//  为什么要有它：以前从相册选了图之后，球上直接按「填满 + 居中」画出来 ——
//  用户没法决定要哪一块。一张全身照做成球，脸上那部分可能只有几个像素。
//  现在选完图先过这一页：拖动 + 双指缩放，把要的部分对进圆圈里，点「用这张」。
//
//  ⚠️ 选的是**正方形**（圆心那个圆是提示，球本身是圆的，圆外那圈不会显示）。
//     产出的图直接当「用户原图」存起来（BallRenderer.saveCustomImage），
//     之后球怎么画、颜色怎么换都不受影响。
//
//  ⚠️ 不用 SwiftUI 的 PhotosPicker（那个要 iOS 16+），本页只吃一张 UIImage，
//     相册那一层还是 CustomImagePicker（PHPicker，免相册权限）。
//

import SwiftUI
import UIKit

struct IconCropView: View {

    let source: UIImage
    let onCancel: () -> Void
    let onDone: (UIImage) -> Void

    /// 画布边长（方的那块）
    private var side: CGFloat { min(UIScreen.main.bounds.width - 76, 300) }

    @State private var zoom: CGFloat = 1.0            // 已提交的缩放（1.0 ~ 5.0）
    @State private var offset: CGSize = .zero         // 已提交的位移
    @GestureState private var pinch: CGFloat = 1.0    // 手势进行中的临时缩放
    @GestureState private var drag: CGSize = .zero    // 手势进行中的临时位移

    /// 手势进行中也算上，这样画面上跟着手指动
    private var liveZoom: CGFloat { min(max(zoom * pinch, 1.0), 5.0) }
    private var liveOffset: CGSize {
        CGSize(width: offset.width + drag.width, height: offset.height + drag.height)
    }

    /// 图在画布上的绘制尺寸（按「填满画布」再乘缩放）
    private func drawnSize(zoom z: CGFloat) -> CGSize {
        let w = max(source.size.width, 1)
        let h = max(source.size.height, 1)
        let base = max(side / w, side / h)
        return CGSize(width: w * base * z, height: h * base * z)
    }

    private var drawn: CGSize { drawnSize(zoom: liveZoom) }

    var body: some View {
        NavigationView {
            VStack(spacing: 14) {
                Text("拖动、双指缩放，把要放进球里的部分对到圆圈里。圆圈外面的不会显示。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                ZStack {
                    Color(UIColor.secondarySystemBackground)

                    Image(uiImage: source)
                        .resizable()
                        .frame(width: drawn.width, height: drawn.height)
                        .offset(x: liveOffset.width, y: liveOffset.height)

                    dimOutsideCircle
                }
                .frame(width: side, height: side)
                .clipped()
                .contentShape(Rectangle())
                .gesture(dragGesture)
                .simultaneousGesture(pinchGesture)

                HStack(spacing: 16) {
                    Text("缩放 \(Int((liveZoom * 100).rounded()))%")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Button("复位") {
                        zoom = 1.0
                        offset = .zero
                    }
                    .font(.footnote)
                }
            }
            .padding(.vertical)
            .navigationTitle("选一块")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("用这张") { onDone(croppedImage()) }
                }
            }
        }
    }

    /// 圆外压暗：一眼看出球上到底会显示哪一块
    private var dimOutsideCircle: some View {
        Rectangle()
            .fill(Color.black.opacity(0.55))
            .mask(
                ZStack {
                    Rectangle()
                    Circle()
                        .frame(width: side, height: side)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            )
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                    .frame(width: side, height: side)
            )
            .allowsHitTesting(false)
    }

    // MARK: - 手势

    private var dragGesture: some Gesture {
        DragGesture()
            .updating($drag) { value, state, _ in state = value.translation }
            .onEnded { value in
                offset = clamped(CGSize(width: offset.width + value.translation.width,
                                        height: offset.height + value.translation.height),
                                 zoom: zoom)
            }
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .updating($pinch) { value, state, _ in state = value }
            .onEnded { value in
                let z = min(max(zoom * value, 1.0), 5.0)
                zoom = z
                offset = clamped(offset, zoom: z)
            }
    }

    /// 位移不许露出空白：图必须始终盖满画布
    private func clamped(_ value: CGSize, zoom z: CGFloat) -> CGSize {
        let d = drawnSize(zoom: z)
        let maxX = max(0, (d.width - side) / 2)
        let maxY = max(0, (d.height - side) / 2)
        return CGSize(width: min(max(value.width, -maxX), maxX),
                      height: min(max(value.height, -maxY), maxY))
    }

    // MARK: - 出图

    /// 把画布上看到的那一块画成 1024×1024 的正方形图（和画布同一套几何，放大 k 倍）
    private func croppedImage() -> UIImage {
        let out: CGFloat = 1024
        let k = out / side
        let z = min(max(zoom, 1.0), 5.0)
        let d = drawnSize(zoom: z)
        let off = clamped(offset, zoom: z)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1          // out 已经是像素了
        format.opaque = false

        let size = CGSize(width: out, height: out)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let rect = CGRect(x: (side / 2 - d.width / 2 + off.width) * k,
                              y: (side / 2 - d.height / 2 + off.height) * k,
                              width: d.width * k,
                              height: d.height * k)
            source.draw(in: rect)
        }
    }
}
