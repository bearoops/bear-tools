//
//  FilePicker.swift
//  bocl
//
//  Created by 小熊 on 2025/9/30.
//

import Foundation
import PhotosUI
import CoreServices

@MainActor @objc(SailFilePicker)
public class FilePicker: NSObject, UIAdaptivePresentationControllerDelegate {
        
    public static let shared = FilePicker()
    
    var checkedContnts: [Mode: CheckedContinuation<Any, Error>] = [:]
    
    public func pickFromAlbum(
        limit count: Int = 1,
        mime types: [MIME] = [.anyImage, .anyVideo]
    ) async throws -> [Result] {
        if #available(iOS 14.0, *) {
            var config = PHPickerConfiguration(photoLibrary: .shared())
            config.selectionLimit = count
            var pfs: Set<PHPickerFilter> = []
            for type in types {
                if type.isImage {
                    pfs.insert(.images)
                    pfs.insert(.livePhotos)
                } else if type.isVideo {
                    pfs.insert(.videos)
                }
            }
            config.filter = pfs.isEmpty ? nil : .any(of: Array(pfs))
            let pickerCtr = PHPickerViewController(configuration: config)
            pickerCtr.delegate = self
            pickerCtr.presentationController?.delegate = self
            UIApplication.shared.bt.present(pickerCtr, animated: true)
        } else {
            let pickerCtr = UIImagePickerController()
            pickerCtr.sourceType = .photoLibrary
            if !types.isEmpty {
                pickerCtr.mediaTypes = types.map { $0.contentType }
            }
            pickerCtr.delegate = self
            UIApplication.shared.bt.present(pickerCtr, animated: true)
        }
        return try await withCheckedThrowingContinuation { cont in
            self.checkedContnts[.album] = cont
        } as! [Result]
    }
    
    public func pickFromCamera() async throws -> UIImage {
        let pickerCtr = UIImagePickerController()
        pickerCtr.sourceType = .camera
        pickerCtr.delegate = self
        pickerCtr.presentationController?.delegate = self
        UIApplication.shared.bt.present(pickerCtr, animated: true)
        return try await withCheckedThrowingContinuation { cont in
            self.checkedContnts[.camera] = cont
        } as! UIImage
    }
    
    /**
     选取系统App中的文件
     @param multiselect 是否多选
     */
    public func pickFromFileApp(
        multiselect: Bool = false,
        mime types: [MIME] = [.any]
    ) async throws -> [Result] {
        let mts = types.isEmpty ? [.any] : types
        let pickerCtr: UIDocumentPickerViewController
        if #available(iOS 14.0, *) {
            let utts = mts.compactMap { $0.utType }
            pickerCtr = UIDocumentPickerViewController(forOpeningContentTypes: utts)
        } else {
            let utis = mts.compactMap { $0.uti }
            pickerCtr = UIDocumentPickerViewController(documentTypes: utis, in: .import)
        }
        pickerCtr.delegate = self
        pickerCtr.presentationController?.delegate = self
        pickerCtr.allowsMultipleSelection = multiselect
        UIApplication.shared.bt.present(pickerCtr, animated: true)
        return try await withCheckedThrowingContinuation { cont in
            self.checkedContnts[.file] = cont
        } as! [Result]
    }
    
    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        var conti: CheckedContinuation<Any, Error>?
        for mode in Mode.allCases {
            if let contnt = self.checkedContnts[mode] {
                conti = contnt
                self.checkedContnts[mode] = nil
                break
            }
        }
        if let conti {
            conti.resume(throwing: Err.cancel)
        }
    }
    
    public enum Mode: String, CaseIterable, Identifiable {
        case album, camera, file
        
        public var id: String { rawValue }
    }

    public enum Err: Error {
        case authDenied, cancel, unaccessible
        case loadImageFailed(Error?)
        case loadFileFailed(Error?)
        case copyFileFailed(Error?)
    }
    
    public struct Result {
        public let mime: MIME
        public let name: String
        public let url: URL?
        public let item: NSItemProvider?
        public let assetId: String?
        
        public init(mime: MIME, name: String, url: URL? = nil,
                    item: NSItemProvider? = nil, assetId: String? = nil) {
            self.mime = mime
            self.name = name
            self.url = url
            self.item = item
            self.assetId = assetId
        }
    }
    
}

extension FilePicker: PHPickerViewControllerDelegate, UIDocumentPickerDelegate,
                      UIImagePickerControllerDelegate & UINavigationControllerDelegate {
    
    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let contnt = self.checkedContnts[.file] else {
            return
        }
        self.checkedContnts[.file] = nil
        guard !urls.isEmpty else {
            contnt.resume(throwing: Err.cancel)
            return
        }
        DispatchQueue.global().async {
            var results: [Result] = []
            var errors: [Error] = []
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else {
                    errors.append(Err.unaccessible)
                    continue
                }
                var toUrl = FileManager.default.temporaryDirectory
                toUrl.appendPathComponent(url.lastPathComponent)
                var mime = MIME.any
                do {
                    try FileManager.default.bt.copyItem(at: url, to: toUrl)
                    let rvs = try url.resourceValues(forKeys: [.typeIdentifierKey])
                    if let uti = rvs.typeIdentifier,
                        let mm = MIME.mime(from: [uti]) {
                        mime = mm
                    }
                    let result = Result(mime: mime,
                                        name: url.lastPathComponent,
                                        url: toUrl)
                    results.append(result)
                } catch {
                    errors.append(Err.copyFileFailed(error))
                }
                url.stopAccessingSecurityScopedResource()
            }
            DispatchQueue.main.async {
                if let error = errors.first {
                    contnt.resume(throwing: error)
                } else {
                    contnt.resume(returning: results)
                }
            }
        }
    }
    
    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard let contnt = self.checkedContnts[.file] else {
            return
        }
        contnt.resume(throwing: Err.cancel)
        self.checkedContnts[.file] = nil
    }
       
    @available(iOS 14, *)
    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true) {
            guard let contnt = self.checkedContnts[.album] else {
                return
            }
            self.checkedContnts[.album] = nil
            guard !results.isEmpty else {
                contnt.resume(throwing: Err.cancel)
                return
            }
            var fprs: [Result] = []
            for result in results {
                var mime = MIME.any
                let utis = result.itemProvider.registeredTypeIdentifiers
                if let mm = MIME.mime(from: utis) {
                    mime = mm
                }
                let name = result.itemProvider.suggestedName ?? ""
                let fpr = Result(mime: mime, name: name,
                                 item: result.itemProvider,
                                 assetId: result.assetIdentifier)
                fprs.append(fpr)
            }
            contnt.resume(returning: fprs)
        }
    }
    
    public func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        picker.dismiss(animated: true) {
            let mode: Mode = picker.sourceType == .camera ? .camera : .album
            guard let contnt = self.checkedContnts[mode],
                  let _ = info[.mediaType] as? String else {
                return
            }
            self.checkedContnts[mode] = nil
            if let image = info[.originalImage] {
                if mode == .camera {
                    contnt.resume(returning: image)
                } else {
                    contnt.resume(returning: [])
                }
            } else {
                contnt.resume(throwing: Err.cancel)
            }
        }
    }
    
    public func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true) {
            let mode: Mode = picker.sourceType == .camera ? .camera : .album
            guard let contnt = self.checkedContnts[mode] else {
                return
            }
            contnt.resume(throwing: Err.cancel)
            self.checkedContnts[mode] = nil
        }
    }
    
}

extension FilePicker.Result {
    
    public func loadAssetSize() -> Int {
        guard let assetId = self.assetId else {
            return -1
        }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        guard let asset = assets.firstObject else {
            return -1
        }
        let resources = PHAssetResource.assetResources(for: asset)
        if let resource = resources.first,
            let size = resource.value(forKey: "fileSize") as? Int {
            return size
        }
        return -1
    }
    
    public func loadImage() async throws -> UIImage {
        guard let item else {
            throw FilePicker.Err.loadImageFailed(nil)
        }
        return try await withCheckedThrowingContinuation { conti in
            item.loadObject(ofClass: UIImage.self) { object, error in
                if let image = object as? UIImage {
                    conti.resume(returning: image)
                } else {
                    conti.resume(throwing: FilePicker.Err.loadImageFailed(error))
                }
            }
        }
    }
    
    public func loadFileUrl() async throws -> URL {
        guard let item, let uti = self.mime.uti else {
            throw FilePicker.Err.loadFileFailed(nil)
        }
        return try await withCheckedThrowingContinuation { conti in
            item.loadFileRepresentation(forTypeIdentifier: uti) { url, err in
                guard let url else {
                    conti.resume(throwing: FilePicker.Err.loadFileFailed(err))
                    return
                }
                let toUrl = FileManager.default.temporaryDirectory
                    .appendingPathComponent(url.lastPathComponent)
                // 没有同名文件不影响继续执行
                try? FileManager.default.removeItem(at: toUrl)
                do {
                    // url 是一个临时文件，需要 copy 到自己的目录
                    try FileManager.default.moveItem(at: url, to: toUrl)
                    conti.resume(returning: toUrl)
                } catch {
                    conti.resume(throwing: error)
                }
            }
        }
    }
    
    public func loadImageInVideo(url: URL, at time: CMTime? = nil) throws -> UIImage {
        let generator = AVAssetImageGenerator(asset: AVAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        let cmtime = time ?? CMTime(seconds: 0, preferredTimescale: 600)
        let cgImage = try generator.copyCGImage(at: cmtime, actualTime: nil)
        return UIImage(cgImage: cgImage)
    }
    
}
