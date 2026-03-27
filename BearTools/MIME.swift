//
//  MIME.swift
//  SailBaseTools
//
//  Created by 小熊 on 2025/12/8.
//

import Foundation
import UniformTypeIdentifiers
import MobileCoreServices

/// MIME 类型结构体
public struct MIME: Hashable {
    
    /// 主类型（如：image, application, text 等）
    public let type: String
    /// 子类型（如：jpeg, pdf, plain 等）
    public let subtype: String
    /// 参数列表（如：charset=utf-8）
    public let parameters: [String: String]
    
    /// 从字符串初始化 MIME 类型
    /// - Parameter string: MIME 类型字符串，如 "image/jpeg" 或 "text/html; charset=utf-8"
    public init?(_ string: String) {
        let components = string.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard components.count > 0 else { return nil }
        let typeParts = components[0].components(separatedBy: "/")
        guard typeParts.count == 2,
              !typeParts[0].isEmpty,
              !typeParts[1].isEmpty else {
            return nil
        }
        self.type = typeParts[0].lowercased()
        self.subtype = typeParts[1].lowercased()
        // 解析参数
        var params: [String: String] = [:]
        for i in 1..<components.count {
            let paramParts = components[i].components(separatedBy: "=")
            if paramParts.count == 2 {
                let key = paramParts[0].trimmingCharacters(in: .whitespaces)
                let value = paramParts[1].trimmingCharacters(in: .whitespaces)
                params[key] = value
            }
        }
        self.parameters = params
    }
    
    /// 从类型和子类型初始化
    /// - Parameters:
    ///   - type: 主类型
    ///   - subtype: 子类型
    ///   - parameters: 参数列表
    public init(type: String, subtype: String,
                parameters: [String: String] = [:]) {
        self.type = type.lowercased()
        self.subtype = subtype.lowercased()
        self.parameters = parameters
    }
    
    /// 主类型和子类型（不带参数）
    public var contentType: String {
        "\(type)/\(subtype)"
    }
    
    /// 完整的 MIME 类型字符串
    public var stringValue: String {
        var result = "\(type)/\(subtype)"
        if !parameters.isEmpty {
            let paramsString = parameters.map { "\($0.key)=\($0.value)" }
                .joined(separator: "; ")
            result += "; \(paramsString)"
        }
        return result
    }
    
}

extension MIME: ExpressibleByStringLiteral, CustomStringConvertible {
    
    public var description: String {
        stringValue
    }
    
    public init(stringLiteral value: String) {
        if let mime = MIME(value) {
            self = mime
        } else {
            self.type = "application"
            self.subtype = "octet-stream"
            self.parameters = [:]
        }
    }
    
}

extension Set where Element == MIME {
    /// 检查是否接受指定的 MIME 类型
    public func accepts(_ MIME: MIME) -> Bool {
        // 如果集合中包含通配符，检查主类型
        for accepted in self {
            if accepted.subtype == "*" && accepted.type == MIME.type {
                return true
            }
            if accepted == MIME {
                return true
            }
        }
        return false
    }
    
    /// 从字符串数组创建集合
    public init(_ strings: [String]) {
        self = Set(strings.compactMap { MIME($0) })
    }
}

extension MIME: Codable, CaseIterable {
    
    public static var allCases: [MIME] = [
        .jpeg, .png, .gif, .webp, .heic,
        .mp4, .quicktime, .mpeg, .avi,
        .pdf, .json, .zip, .octetStream,
        .plainText, .html, .css, .csv,
        .mp3, .wav, .aac
    ]
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let MIME = MIME(string) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "无效的 MIME 类型字符串: \(string)"
            )
        }
        self = MIME
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }
    
}

extension MIME {
    /// 从 HTTP 头部 Content-Type 解析
    public static func fromHttpHeader(contentType: String) -> MIME? {
        // 移除可能的字符集参数
        let components = contentType
            .components(separatedBy: ";")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let mimeString = components else { return nil }
        return MIME(mimeString)
    }
    
    /// 转换为 HTTP 头部格式
    public func toHttpHeader(charset: String? = nil) -> String {
        var result = stringValue
        if let charset = charset, parameters["charset"] == nil {
            result += "; charset=\(charset)"
        }
        return result
    }
}

extension MIME {
    
    public var uti: String? {
        let cfMime = contentType as CFString
        guard let cfUti = UTTypeCreatePreferredIdentifierForTag(
            kUTTagClassMIMEType,
            cfMime,
            nil
        ) else {
            return nil
        }
        return cfUti.takeRetainedValue() as String
    }

    public static func mime(from utis: [String]) -> MIME? {
        for uti in utis {
            let cfUti = uti as CFString
            guard let cfMime = UTTypeCopyPreferredTagWithClass(
                cfUti,
                kUTTagClassMIMEType
            ) else {
                continue
            }
            let mimeStr = cfMime.takeRetainedValue() as String
            return MIME(mimeStr)
        }
        return nil
    }
    
    @available(iOS 14.0, *)
    public var utType: UTType? {
        switch type {
        case "*":
            return .item
        default:
            return UTType(mimeType: contentType)
        }
    }
    
    @available(iOS 14.0, *)
    public init?(utType: UTType) {
        guard let MIME = utType.preferredMIMEType else { return nil }
        self.init(MIME)
    }
    
    @available(iOS 14.0, *)
    public func conforms(to utType: UTType) -> Bool {
        guard let selfUTType = self.utType else { return false }
        return selfUTType.conforms(to: utType)
    }

    public func conforms(to mime: MIME) -> Bool {
        if mime.type == "*" {
            return true
        }
        if mime.type != type {
            return false
        }
        if mime.subtype == "*" {
            return true
        }
        if mime.subtype != subtype {
            return false
        }
        return true
    }
    
}

extension MIME {
    
    public static let jpeg = MIME(type: "image", subtype: "jpeg")
    public static let png = MIME(type: "image", subtype: "png")
    public static let gif = MIME(type: "image", subtype: "gif")
    public static let webp = MIME(type: "image", subtype: "webp")
    public static let heic = MIME(type: "image", subtype: "heic")
    public static let heif = MIME(type: "image", subtype: "heif")

    public static let mp4 = MIME(type: "video", subtype: "mp4")
    public static let quicktime = MIME(type: "video", subtype: "quicktime")
    public static let mpeg = MIME(type: "video", subtype: "mpeg")
    public static let avi = MIME(type: "video", subtype: "avi")
    
    public static let pdf = MIME(type: "application", subtype: "pdf")
    public static let json = MIME(type: "application", subtype: "json")
    public static let zip = MIME(type: "application", subtype: "zip")
    public static let octetStream = MIME(type: "application", subtype: "octet-stream")
    
    public static let plainText = MIME(type: "text", subtype: "plain")
    public static let html = MIME(type: "text", subtype: "html")
    public static let css = MIME(type: "text", subtype: "css")
    public static let csv = MIME(type: "text", subtype: "csv")
    
    public static let mp3 = MIME(type: "audio", subtype: "mpeg")
    public static let wav = MIME(type: "audio", subtype: "wav")
    public static let aac = MIME(type: "audio", subtype: "aac")
    
    // 通配符类型
    public static let anyImage = MIME(type: "image", subtype: "*")
    public static let anyVideo = MIME(type: "video", subtype: "*")
    public static let anyAudio = MIME(type: "audio", subtype: "*")
    public static let anyText = MIME(type: "text", subtype: "*")
    public static let anyApplication = MIME(type: "application", subtype: "*")
    public static let any = MIME(type: "*", subtype: "*")
    
    public var isImage: Bool { type == "image" }
    public var isVideo: Bool { type == "video" }
    public var isAudio: Bool { type == "audio" }
    public var isText: Bool { type == "text" }
    public var isApplication: Bool { type == "application" }

}

extension MIME {
    
    public static let extToMimeMap: [String: MIME] = [
        "jpg": .jpeg, "jpeg": .jpeg,
        "png": .png,
        "gif": .gif,
        "webp": .webp,
        "heic": .heic, "heif": .heif,
        "pdf": .pdf,
        "zip": .zip,
        "txt": .plainText,
        "html": .html, "htm": .html,
        "css": .css,
        "json": .json,
        "mp4": .mp4,
        "mp3": .mp3,
        "wav": .wav
    ]
    
    public static let mimeToExtMap: [MIME: [String]] = [
        .jpeg: ["jpg", "jpeg"],
        .png: ["png"],
        .gif: ["gif"],
        .webp: ["webp"],
        .heic: ["heic"], .heif: ["heif"],
        .pdf: ["pdf"],
        .zip: ["zip"],
        .plainText: ["txt"],
        .html: ["html", "htm"],
        .css: ["css"],
        .json: ["json"],
        .mp4: ["mp4"],
        .mp3: ["mp3"],
        .wav: ["wav"]
    ]
    
}
