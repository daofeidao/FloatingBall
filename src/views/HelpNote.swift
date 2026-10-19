//
//  HelpNote.swift
//
//  「这一节怎么用」的折叠入口（0.1.38，用户 2026-10-20 要求）。
//
//  用户原话：每一页下面那几段说明文字太长，页面显得乱 —— 收成一个小 `*`，
//  想看的时候点开看一眼。
//
//  用法（两行）：
//      Section(header: helpHeader("悬浮球", Self.ballHelp)) { ... }
//      Section(header: helpHeader("版本记录", Self.versionFooter)) { EmptyView() }
//
//  ⚠️ 长文案仍然要提成 `static let`（以前 Section(footer:) 里现拼长字符串，
//     CI 上的 Swift 编译器报过 `unable to type-check this expression in reasonable time`）。
//

import SwiftUI

/// 一个小 `*` 按钮：点开弹一层，看这一节的说明。
struct HelpNoteButton: View {

    let title: String
    let text: String

    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "asterisk")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.accentColor)
                // ⚠️ 点上去要够得着：`*` 本身很小，靠 padding + contentShape 把
                //    可点范围撑到 ~28×26pt（小节标题里塞不下 44pt 的标准行高）。
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showing) {
            NavigationView {
                ScrollView {
                    Text(text)
                        .font(.footnote)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding()
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("好") { showing = false }
                    }
                }
            }
        }
    }
}

/// 小节标题 + 右边一个 `*` —— 传进来的是「这一节原来那段 footer 文字」。
func helpHeader(_ title: String, _ text: String) -> some View {
    HStack(spacing: 0) {
        Text(title)
        HelpNoteButton(title: title, text: text)
        Spacer(minLength: 0)
    }
}
