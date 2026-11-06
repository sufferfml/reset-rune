// INPUT: Pinned Codex 0.153.0 account and quota responses.
// OUTPUT: v1 normalized snapshots, preserving unknown inventory and raw identity.
// POS: Official transport normalization; see native/README.md.
import Foundation
import CoreFoundation
import CryptoKit
import RuneCore

let jsonNull = NSNull()
func wholeNumber(_ value: Any?, min: Double = 0, max: Double = 9_007_199_254_740_991) -> Double? {
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
    let d = n.doubleValue
    return d.isFinite && d.rounded(.towardZero) == d && d >= min && d <= max ? d : nil
}
func epochMilliseconds(_ value: Any?) -> Any {
    guard let seconds = wholeNumber(value, min: 1, max: 8_640_000_000_000) else { return jsonNull }
    return seconds * 1000
}
func safeText(_ value: Any?) -> String? {
    guard let text = value as? String, !text.isEmpty, text.utf16.count <= 512,
          text.trimmingCharacters(in: .whitespacesAndNewlines) == text,
          !text.unicodeScalars.contains(where: { [.control, .format].contains($0.properties.generalCategory) }) else { return nil }
    return text
}
func rawEqual(_ a: String, _ b: String) -> Bool { a.utf16.elementsEqual(b.utf16) }
func normalizeWindow(_ input: Any?) -> JSONObject? {
    guard let value = input as? JSONObject else { return nil }
    return ["remainingPercent": wholeNumber(value["usedPercent"], max: 100).map { 100 - $0 } ?? jsonNull,
            "durationMinutes": wholeNumber(value["windowDurationMins"], min: 1) ?? jsonNull,
            "resetsAt": epochMilliseconds(value["resetsAt"])]
}
func windowJSON(_ value: JSONObject?) -> String {
    guard let value else { return "null" }
    func number(_ key: String) -> String {
        guard let d = wholeNumber(value[key]) else { return "null" }
        return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), d)
    }
    // JSON.stringify's original object field order is part of the v1 journal contract.
    return "{\"remainingPercent\":\(number("remainingPercent")),\"durationMinutes\":\(number("durationMinutes")),\"resetsAt\":\(number("resetsAt"))}"
}

public func normalizeCodexSnapshot(account: JSONObject?, usage: JSONObject?) -> JSONObject {
    let summary = usage?["rateLimitResetCredits"] as? JSONObject
    let count = wholeNumber(summary?["availableCount"])
    let rows = summary?["credits"] as? [Any]
    var credits: [JSONObject] = []
    var seen: [[UInt16]: JSONObject] = [:]
    var order: [[UInt16]] = []
    var duplicates = Set<[UInt16]>()
    if let rows, count != 0 {
        for item in rows {
            guard let row = item as? JSONObject, let id = safeText(row["id"]) else { continue }
            let key = Array(id.utf16)
            if seen[key] != nil { duplicates.insert(key) } else { order.append(key) }
            seen[key] = row
        }
        for key in order {
            guard !duplicates.contains(key), let row = seen[key], row["status"] as? String == "available",
                  row["resetType"] as? String == "codexRateLimits", let id = row["id"] as? String else { continue }
            credits.append(["id": id, "expiresAt": epochMilliseconds(row["expiresAt"])])
        }
    }
    var result: JSONObject = ["identity": jsonNull, "availableCount": count ?? jsonNull,
        "creditsKnown": rows != nil, "credits": credits, "remainingPercent": jsonNull,
        "limitId": jsonNull, "primary": jsonNull, "secondary": jsonNull,
        "redeemablePercent": jsonNull, "quotaRevision": jsonNull]
    guard let account, account["type"] as? String == "chatgpt" else {
        result["availableCount"] = jsonNull; result["creditsKnown"] = false; result["credits"] = [JSONObject]()
        return result
    }
    let singleBucket = usage?["rateLimits"] as? JSONObject
    let codex = (usage?["rateLimitsByLimitId"] as? JSONObject)?["codex"] as? JSONObject
    func acceptable(_ bucket: JSONObject?) -> Bool {
        guard let bucket else { return false }
        return bucket["limitId"] == nil || bucket["limitId"] is NSNull || bucket["limitId"] as? String == "codex"
    }
    let fromCodex = acceptable(codex)
    let bucket = fromCodex ? codex : acceptable(singleBucket) ? singleBucket : nil
    let primary = normalizeWindow(bucket?["primary"])
    let secondary = normalizeWindow(bucket?["secondary"])
    let email = safeText(account["email"])
    let accountId = safeText(usage?["accountId"])
    let verified = bucket != nil && (fromCodex || bucket?["limitId"] as? String == "codex")
    var scope: Any = jsonNull
    if verified, accountId != nil, let email {
        scope = "codex:" + SHA256.hash(data: Data(email.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    result["identity"] = ["accountId": accountId ?? jsonNull, "scope": scope, "email": email ?? jsonNull] as JSONObject
    result["remainingPercent"] = primary?["remainingPercent"] ?? jsonNull
    result["limitId"] = safeText(bucket?["limitId"]) ?? jsonNull
    result["primary"] = primary ?? jsonNull; result["secondary"] = secondary ?? jsonNull
    let remaining = [primary, secondary].compactMap { wholeNumber($0?["remainingPercent"], max: 100) }
    result["redeemablePercent"] = verified ? remaining.min() ?? jsonNull : jsonNull
    result["quotaRevision"] = verified ? "[\(windowJSON(primary)),\(windowJSON(secondary))]" : jsonNull
    return result
}
