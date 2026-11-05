//
//  striusTests.swift
//  striusTests
//
//  Created by 宮氏朋愛 on 2026/04/17.
//

import Foundation
import Testing
@testable import strius

struct striusTests {

    @Test func assistantTextReadabilityAddsLineBreaksToDenseReply() {
        let raw = "OKです。前にやっていた物理だと、候補は「斜方投射・速度の成分」と「物理学A 第4回の力・作用反作用」です。まずどちらからテスト対策しますか？選んでくれた方で、確認問題を1問出します。"

        let formatted = ChatTextReadability.formatAssistantText(raw)

        #expect(
            formatted == """
            OKです。
            前にやっていた物理だと、候補は「斜方投射・速度の成分」と「物理学A 第4回の力・作用反作用」です。
            まずどちらからテスト対策しますか？
            選んでくれた方で、確認問題を1問出します。
            """
        )
    }

    @Test func assistantTextHeadingsBecomeBold() {
        #expect(ChatTextReadability.emboldenHeadings("## 手がかり\n本文 #1 です\n#タグ") == "**手がかり**\n本文 #1 です\n#タグ")
        #expect(ChatTextReadability.emboldenHeadings("### **問題の箇所** ###") == "**問題の箇所**")
    }

    @Test @MainActor func plainTextBoldIsRendered() {
        let text = StruisInlineMarkdown.attributed("前の行は **合っています**。a * b と ____ は残す")
        #expect(String(text.characters) == "前の行は 合っています。a * b と ____ は残す")
        let bold = text.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.map { String(text[$0.range].characters) }
        #expect(bold == ["合っています"])
    }

    @Test func assistantTextReadabilityPreservesExplicitLineBreaks() {
        let raw = "OKです。\\nまずは斜方投射からいきましょう。"

        let formatted = ChatTextReadability.formatAssistantText(raw)

        #expect(
            formatted == """
            OKです。
            まずは斜方投射からいきましょう。
            """
        )
    }

}
