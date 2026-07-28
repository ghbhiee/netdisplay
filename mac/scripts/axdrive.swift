#!/usr/bin/env swift
//
// axdrive — drive a macOS app through the Accessibility API, by *name* not by pixel.
//
// Why this exists: clicking screen coordinates is brittle (layout shifts, Retina
// scaling, the window moves, another window steals focus) and it fights the human
// for the cursor. AX presses a control semantically — no mouse movement, no focus
// steal, and it keeps working while the user is using the machine.
//
// Run it directly (no build step, no dependencies):
//   swift scripts/axdrive.swift dump  [--app NetDisplay] [--all]
//   swift scripts/axdrive.swift press <identifier> [--app NetDisplay]
//   swift scripts/axdrive.swift get   <identifier>
//   swift scripts/axdrive.swift wait  <identifier> [--timeout 10]
//
// Identifiers come from the app calling `setAccessibilityIdentifier` — the
// convention lives in docs/30-ax-conventions.md.
//
// Requires: whatever runs this must be granted
// System Settings → Privacy & Security → Accessibility.

import AppKit
import ApplicationServices

// MARK: - AX helpers

func axAttr(_ el: AXUIElement, _ name: String) -> Any? {
    var out: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &out) == .success ? out : nil
}

func axString(_ el: AXUIElement, _ name: String) -> String {
    guard let v = axAttr(el, name) else { return "" }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return ""
}

struct Node {
    let depth: Int
    let identifier: String
    let role: String
    let label: String
    let value: String
    let enabled: Bool?
    let element: AXUIElement
}

/// Depth-first walk of the AX tree.
func walk(_ el: AXUIElement, depth: Int = 0, into acc: inout [Node], maxDepth: Int = 25) {
    if depth > maxDepth { return }
    let title = axString(el, kAXTitleAttribute)
    let desc = axString(el, kAXDescriptionAttribute)
    var enabled: Bool? = nil
    if let e = axAttr(el, kAXEnabledAttribute) as? NSNumber { enabled = e.boolValue }
    acc.append(Node(depth: depth,
                    identifier: axString(el, "AXIdentifier"),
                    role: axString(el, kAXRoleAttribute),
                    label: title.isEmpty ? desc : title,
                    value: axString(el, kAXValueAttribute),
                    enabled: enabled,
                    element: el))
    if let kids = axAttr(el, kAXChildrenAttribute) as? [AXUIElement] {
        for k in kids { walk(k, depth: depth + 1, into: &acc, maxDepth: maxDepth) }
    }
}

func tree(app: String) -> [Node] {
    guard let running = NSWorkspace.shared.runningApplications.first(where: {
        ($0.localizedName ?? "") == app
    }) else {
        FileHandle.standardError.write("找不到正在运行的 App: \(app)\n".data(using: .utf8)!)
        exit(2)
    }
    var acc: [Node] = []
    walk(AXUIElementCreateApplication(running.processIdentifier), into: &acc)
    return acc
}

// MARK: - CLI

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String, _ def: String) -> String {
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return def }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
func boolFlag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: "--\(name)") else { return false }
    args.remove(at: i)
    return true
}

let showAll = boolFlag("all")
let appName = flag("app", "NetDisplay")
let timeout = Double(flag("timeout", "10")) ?? 10
let cmd = args.first ?? "dump"
let target = args.count > 1 ? args[1] : ""

if !AXIsProcessTrusted() {
    FileHandle.standardError.write(
        "⚠️  没有「辅助功能」权限：系统设置 → 隐私与安全性 → 辅助功能，把运行本脚本的终端加进去并勾选。\n"
            .data(using: .utf8)!)
}

switch cmd {
case "dump":
    for n in tree(app: appName) {
        // Hide pure layout containers unless --all: they have neither id nor label.
        if !showAll && n.identifier.isEmpty && n.label.isEmpty { continue }
        var parts = [String(repeating: "  ", count: n.depth) + n.role]
        if !n.identifier.isEmpty { parts.append("#\(n.identifier)") }
        if !n.label.isEmpty { parts.append("\"\(n.label)\"") }
        if !n.value.isEmpty { parts.append("=\(n.value)") }
        if n.enabled == false { parts.append("(disabled)") }
        print(parts.joined(separator: " "))
    }

case "wait":
    guard !target.isEmpty else { exit(1) }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if tree(app: appName).contains(where: { $0.identifier == target }) {
            print("found \(target)"); exit(0)
        }
        Thread.sleep(forTimeInterval: 0.3)
    }
    FileHandle.standardError.write("超时：\(timeout)s 内没等到 \(target)\n".data(using: .utf8)!)
    exit(3)

case "get", "press":
    guard !target.isEmpty else {
        FileHandle.standardError.write("需要 <identifier>\n".data(using: .utf8)!); exit(1)
    }
    guard let n = tree(app: appName).first(where: { $0.identifier == target }) else {
        FileHandle.standardError.write("找不到 identifier=\(target)（先跑 dump 看看有哪些）\n".data(using: .utf8)!)
        exit(4)
    }
    if cmd == "get" {
        print("id=\(n.identifier) role=\(n.role) label=\"\(n.label)\" value=\"\(n.value)\" enabled=\(n.enabled.map(String.init) ?? "-")")
        exit(0)
    }
    if n.enabled == false {
        FileHandle.standardError.write("\(target) 当前禁用，不按（多半是前置条件没满足）\n".data(using: .utf8)!)
        exit(5)
    }
    let err = AXUIElementPerformAction(n.element, kAXPressAction as CFString)
    if err != .success {
        FileHandle.standardError.write("press 失败 err=\(err.rawValue) —— 该元素可能没实现 AXPress\n".data(using: .utf8)!)
        exit(6)
    }
    print("pressed \(target)")

default:
    print("""
    axdrive — 用辅助功能(AX)按名字驱动 macOS App

      swift axdrive.swift dump  [--app NetDisplay] [--all]
      swift axdrive.swift press <identifier> [--app NetDisplay]
      swift axdrive.swift get   <identifier>
      swift axdrive.swift wait  <identifier> [--timeout 10]
    """)
}
