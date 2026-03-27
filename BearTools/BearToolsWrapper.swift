//
//  OptWrapper.swift
//  bocl
//
//  Created by 小熊 on 2025/10/20.
//

import UIKit
import CoreServices
import Security

public struct BearToolsWrapper<Base> {
    public let base: Base
    public init(_ base: Base) {
        self.base = base
    }
}

public protocol BearToolsCompatible {}
extension BearToolsCompatible {
    public var bt: BearToolsWrapper<Self> {
        get { BearToolsWrapper(self) }
        set {}
    }
    public static var bt: BearToolsWrapper<Self>.Type {
        get { BearToolsWrapper<Self>.self }
        set {}
    }
}

@globalActor
private actor BackgroundActor {
    static let shared = BackgroundActor()
}

public enum ToolsError: Error {
    
}

public enum ImageError: Error {
    case noImage
    case sourceFailed
    case thumbnailFailed
    case destinationFailed
    case finalizeFailed
}

extension UIApplication: BearToolsCompatible {}
extension BearToolsWrapper where Base: UIApplication {
    
    public var window: UIWindow? {
        var windowScene: UIWindowScene?
        for scene in base.connectedScenes {
            if let ws = scene as? UIWindowScene {
                windowScene = ws
                if #available(iOS 15.0, *) {
                    if scene.activationState == .foregroundActive,
                       let window = ws.keyWindow  {
                        return window
                    }
                }
            }
        }
        return windowScene?.windows.first
    }
    
    public func present(_ viewCtr: UIViewController, animated flag: Bool,
                 completion: (() -> Void)? = nil) {
        var fromCtr = window?.rootViewController
        while let ctr = fromCtr?.presentedViewController {
            fromCtr = ctr
        }
        fromCtr?.present(viewCtr, animated: flag, completion: completion)
    }

}

extension FileManager: BearToolsCompatible {}
extension BearToolsWrapper where Base: FileManager {
    
    // 先删除再复制
    public func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if base.fileExists(atPath: dstURL.path) {
            try base.removeItem(at: dstURL)
        }
        try base.copyItem(at: srcURL, to: dstURL)
    }
    
    // 先删除再移动
    public func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if base.fileExists(atPath: dstURL.path) {
            try base.removeItem(at: dstURL)
        }
        try base.moveItem(at: srcURL, to: dstURL)
    }
    
    public func valueOfItem(at path: String, key: FileAttributeKey) -> Any? {
        do {
            let attributes = try base.attributesOfItem(atPath: path)
            return attributes[key]
        } catch {
            return nil
        }
    }
    
}

extension String: BearToolsCompatible {}
extension BearToolsWrapper where Base == String {

    public func extToMIME() -> String {
        switch base.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "mov": return "video/quicktime"
        default: return "application/octet-stream"
        }
    }
    
}

extension UIImage: BearToolsCompatible {}
extension BearToolsWrapper where Base: UIImage {
    
    /**
     压缩尺寸大小与数据大小
     
     长度为nil时，跳过尺寸压缩。
     */
    @BackgroundActor
    public func downsampleAndCompress(
        max pixel: Int? = nil,
        size mb: Float,
        type: CFString = kUTTypeJPEG
    ) async throws -> Data {
        let cgImage: CGImage
        if let pixel,
           let data = await base.jpegData(compressionQuality: 1) {
            cgImage = try await data.bt.downsampleImage(max: pixel)
        } else {
            cgImage = try await toCGImage()
        }
        var quality = 1.0
        var data = Data()
        var smb: Float = 0
        repeat {
            data = try await cgImage.bt.compress(quality: quality, type: type)
            smb = Float(data.count) / 1024 / 1024
            //            print(String(format: "quality: %.2f, data: %.2f", quality, smb))
            quality -= 0.1
        } while quality > 0.1 && smb > mb
        return data
    }
    
    @BackgroundActor
    public func toCGImage() async throws -> CGImage {
        var cgImage: CGImage?
        if let cgimage = await base.cgImage {
            cgImage = cgimage
        } else if let ciimage = await base.ciImage {
            let context = CIContext(options: nil)
            cgImage = context.createCGImage(ciimage, from: ciimage.extent)
        }
        if let cgImage {
            return cgImage
        }
        throw ImageError.noImage
    }
    
}

extension CGImage: BearToolsCompatible {}
extension BearToolsWrapper where Base: CGImage {
    
    /**
     压缩图片数据大小
     
     @param type 图片类型
     @param quality 压缩比例
     
     比如：kUTTypeJPEG
     */
    @BackgroundActor
    public func compress(quality: CGFloat, type: CFString = kUTTypeJPEG) async throws -> Data {
//        let date = Date()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else {
            throw ImageError.destinationFailed
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: CGImagePropertyOrientation.up.rawValue
        ]
        CGImageDestinationAddImage(destination, await base, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageError.finalizeFailed
        }
//        let interval = Date().timeIntervalSince(date)
//        print("interval: \(interval) - quality")
        return data as Data
    }
    
}

extension Data: BearToolsCompatible {}
extension BearToolsWrapper where Base == Data {
    
    /**
     压缩尺寸大小
     
     @param pixel 最长边最大像素值
     
     图片强制转换成jpg格式
     */
    @BackgroundActor
    public func downsampleImage(max pixel: Int) async throws -> CGImage {
//        let date = Date()
        guard let source = CGImageSourceCreateWithData(await base as CFData, nil) else {
            throw ImageError.sourceFailed
        }
        // 设置降采样选项
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // 自动修正方向
            kCGImageSourceThumbnailMaxPixelSize: pixel
        ]
        // 创建缩略图（真正的降采样）
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageError.thumbnailFailed
        }
//        let interval = Date().timeIntervalSince(date)
//        print("interval: \(interval) - pixel")
//        print("with: \(cgImage.width), height: \(cgImage.height)")
        return cgImage
    }
    
}

extension UIColor: BearToolsCompatible {}
extension BearToolsWrapper where Base == UIColor {
    
    public static func color(hex: UInt32, alpha: CGFloat = 1) -> UIColor {
        let b = CGFloat(hex & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        return UIColor(red: r, green: g, blue: b, alpha: alpha)
    }
    
    public static func color(hexStr: String, alpha: CGFloat = 1,
                             placeholder: UIColor = .white) -> UIColor {
        var hs = hexStr
        if hs.hasPrefix("#") {
            hs.remove(at: hs.startIndex)
        }
        if hs.count == 6 {
            var hex: UInt64 = 0
            Scanner(string: hs).scanHexInt64(&hex)
            return color(hex: UInt32(hex), alpha: alpha)
        }
        return placeholder
    }
    
    public static var gray3: UIColor {
        color(hex: 0x333333)
    }
    public static var gray6: UIColor {
        color(hex: 0x666666)
    }
    public static var gray9: UIColor {
        color(hex: 0x999999)
    }
    public static var grayc: UIColor {
        color(hex: 0xcccccc)
    }
    public static var graye: UIColor {
        color(hex: 0xeeeeee)
    }
    
    public func image(length: CGFloat) -> UIImage {
        let size = CGSize(width: length, height: length)
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        let ctx = UIGraphicsGetCurrentContext()!
        ctx.setFillColor(base.cgColor)
        let rect = CGRect(origin: .zero, size: size)
        ctx.fill([rect])
        let image = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext();
        return image
    }
    
}

//extension UITableView: OptCompatible {}
extension BearToolsWrapper where Base: UITableView {
    
    public func dequeueOrCreateCell<Cell>(
        identifier: String = "Cell",
        style: UITableViewCell.CellStyle = .default,
        type: Cell.Type = UITableViewCell.self
    ) -> Cell where Cell: UITableViewCell {
        let cell = base.dequeueReusableCell(withIdentifier: identifier)
        if let cell = cell as? Cell {
            return cell
        }
        return type.init(style: style, reuseIdentifier: identifier)
    }
    
}

extension UIView: BearToolsCompatible {}
extension BearToolsWrapper where Base: UIView {
    
    /**
     用Nib创建视图
     
     @param bundle nib在哪个bundle中
     
     Nib的名称要与视图类名相同
     */
    public static func viewFromNib(bundle: Bundle = .main) -> Base? {
        let name = NSStringFromClass(Base.self)
        let components = name.components(separatedBy: ".")
        if let nn = components.last { // Swift有命名空间
            let nib = UINib(nibName: nn, bundle: bundle)
            let view = nib.instantiate(withOwner: nil).first
            return view as? Base
        }
        return nil
    }
    
    public func constraint(edge: UIRectEdge, to view: UIView, insets: UIEdgeInsets = .zero) {
        base.translatesAutoresizingMaskIntoConstraints = false
        var constraints = [NSLayoutConstraint]()
        if (edge.contains(.top)) {
            let constraint = base.topAnchor.constraint(equalTo: view.topAnchor, constant: insets.top)
            constraints.append(constraint)
        }
        if (edge.contains(.bottom)) {
            let constraint = base.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: insets.bottom)
            constraints.append(constraint)
        }
        if (edge.contains(.left)) {
            let constraint = base.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: insets.left)
            constraints.append(constraint)
        }
        if (edge.contains(.right)) {
            let constraint = base.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: insets.right)
            constraints.append(constraint)
        }
        NSLayoutConstraint.activate(constraints)
    }
    
}

extension URLComponents: BearToolsCompatible {}
extension BearToolsWrapper where Base == URLComponents {
    
    /**
     创建URL拆解实例
     
     防止自动解码json字符串
     支持#在?前面的情况
     */
    public static func components(urlString: String) -> URLComponents? {
        var charSet: CharacterSet = .urlQueryAllowed
        charSet.insert("#")
        let urlStr = urlString.addingPercentEncoding(withAllowedCharacters: charSet)
        // 这个方法会对URL解码一次
        var components = URLComponents(string: urlStr ?? urlString)
        if let fragment = components?.fragment,
            var idx = fragment.firstIndex(of: "?") {
            components?.fragment = String(fragment[..<idx])
            idx = fragment.index(after: idx)
            components?.query = String(fragment[idx...])
        }
        return components;
    }
    
    public func addQuery(_ dict: [String: String]) -> URLComponents {
        var items = base.queryItems ?? []
        for (k, v) in dict {
            items.append(URLQueryItem(name: k, value: v))
        }
        var components = base
        components.queryItems = items
        return components
    }
    
    public func queryValue(for key: String) -> String? {
        guard let items = base.queryItems else {
            return nil
        }
        for item in items where item.name == key {
            return item.value
        }
        return nil
    }
    
    public func queryDict() -> [String: String] {
        guard let items = base.queryItems else {
            return [:]
        }
        var result: [String: String] = [:]
        for item in items {
            if !item.name.isEmpty {
                result[item.name] = item.value
            }
        }
        return result
    }
    
    /**
     判断URL的参数是否符合匹配URL的参数
     
     @param pattern 匹配URL
     
     /payment?xxx&a=hello+word=my&
     
     上面URL的参数会被拆分成以下4个Item：
     
     {name = xxx, value = (null)}
     
     {name = , value = aaa},
     
     {name = a, value = hello+word=my},
     
     {name = , value = (null)}
     
     @note 匹配URL没有的参数会被忽略，没有key的参数也会被忽略。
     */
    public func queryConfirms(to pattern: URLComponents) -> Bool {
        guard let patternItems = pattern.queryItems else {
            return true
        }
        let targetMap = base.bt.queryDict()
        for patternItem in patternItems { // 只处理匹配URL有的参数
            if patternItem.name.isEmpty {
                continue // 没有key的参数会被忽略
            }
            let targetValue = targetMap[patternItem.name]
            if targetValue != nil && patternItem.value != nil {
                if targetValue != patternItem.value {
                    return false
                }
            } else if targetValue == nil && patternItem.value == nil {
                
            } else {
                return false
            }
        }
        return true
    }
    
}

extension SecKey: BearToolsCompatible {}
extension BearToolsWrapper where Base == SecKey {
    
    public var base64String: String {
        var error: Unmanaged<CFError>?
        // 1. 获取密钥的外部表示（CFData）
        guard let keyData = SecKeyCopyExternalRepresentation(base, &error) as Data? else {
            return "\(self)"
        }
        // 2. 转换为Base64字符串
        let base64String = keyData.base64EncodedString()
        return base64String
    }
    
}

extension Task: BearToolsCompatible {}
extension BearToolsWrapper where Base == Task<Never, Never> {
    
    public static func sleep(ms: UInt64) async {
        try? await Task.sleep(nanoseconds: ms * 1_000_000)
    }
    
}
