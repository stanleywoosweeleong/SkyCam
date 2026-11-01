import AVFoundation
import Photos
import UIKit

func num(_ v: Any?, _ def: Double = 0) -> Double { (v as? NSNumber)?.doubleValue ?? def }

/// Full-quality capture for one shutter press: three auto-exposure brackets (EV −2 / 0 / +2 around the user's EV),
/// handed to SkyProcessor to merge and grade, then saved to Photos. The web preview releases the camera first.
final class NativeCamera: NSObject, AVCapturePhotoCaptureDelegate {
    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "skycam.camera")
    private let processor = SkyProcessor()
    private var input: AVCaptureDeviceInput?
    private var frames: [(data: Data, bias: Float)] = []
    private var params: [String: Any] = [:]
    private var done: (([String: Any]) -> Void)?
    private var restoreBias: Float?

    func capture(params: [String: Any], done: @escaping ([String: Any]) -> Void) {
        queue.async {
            guard self.done == nil else { done(["ok": false, "error": "busy"]); return }
            self.params = params
            self.done = done
            self.frames = []
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                self.finish(error: "Camera permission missing"); return
            }
            do { try self.configure(lens: params["lens"] as? String ?? "1") } catch {
                self.finish(error: error.localizedDescription); return
            }
            if !self.session.isRunning { self.session.startRunning() }
            Thread.sleep(forTimeInterval: 0.7)   // fresh session: let exposure, focus and white balance settle
            self.shoot()
        }
    }

    private func device(for lens: String) -> AVCaptureDevice? {
        let type: AVCaptureDevice.DeviceType =
            lens == "u" ? .builtInUltraWideCamera : lens == "t" ? .builtInTelephotoCamera : .builtInWideAngleCamera
        return AVCaptureDevice.default(type, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    private func configure(lens: String) throws {
        guard let dev = device(for: lens) else { throw SkyError("No back camera") }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        if input?.device != dev {
            if let i = input { session.removeInput(i); input = nil }
            let ni = try AVCaptureDeviceInput(device: dev)
            guard session.canAddInput(ni) else { throw SkyError("Camera busy") }
            session.addInput(ni)
            input = ni
        }
        if !session.outputs.contains(output) {
            guard session.canAddOutput(output) else { throw SkyError("Photo output unavailable") }
            session.addOutput(output)
        }
        output.maxPhotoQualityPrioritization = .quality
    }

    private func shoot() {
        guard let dev = input?.device else { finish(error: "No camera"); return }
        let ev = Float(num(params["ev"]))
        let clampBias: (Float) -> Float = { max(dev.minExposureTargetBias, min(dev.maxExposureTargetBias, $0)) }
        let heif: [String: Any]? = output.availablePhotoCodecTypes.contains(.hevc) ? [AVVideoCodecKey: AVVideoCodecType.hevc] : nil

        if output.maxBracketedCapturePhotoCount >= 3 {
            let brackets = [ev - 2, ev, ev + 2].map {
                AVCaptureAutoExposureBracketedStillImageSettings.autoExposureSettings(exposureTargetBias: clampBias($0))
            }
            let s = AVCapturePhotoBracketSettings(rawPixelFormatType: 0, processedFormat: heif, bracketedSettings: brackets)
            s.photoQualityPrioritization = .speed   // brackets must be fast so clouds don't move between frames
            output.capturePhoto(with: s, delegate: self)
        } else {
            // No bracketing on this lens: one full-quality frame at the user's EV
            if ev != 0, (try? dev.lockForConfiguration()) != nil {
                restoreBias = dev.exposureTargetBias
                dev.setExposureTargetBias(clampBias(ev), completionHandler: nil)
                dev.unlockForConfiguration()
                Thread.sleep(forTimeInterval: 0.3)
            }
            let s = heif.map { AVCapturePhotoSettings(format: $0) } ?? AVCapturePhotoSettings()
            s.photoQualityPrioritization = .quality
            output.capturePhoto(with: s, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        let bias = (photo.bracketSettings as? AVCaptureAutoExposureBracketedStillImageSettings)?.exposureTargetBias
            ?? Float(num(params["ev"]))
        queue.async { self.frames.append((data, bias)) }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        queue.async {
            if let b = self.restoreBias, let dev = self.input?.device, (try? dev.lockForConfiguration()) != nil {
                dev.setExposureTargetBias(b, completionHandler: nil)
                dev.unlockForConfiguration()
                self.restoreBias = nil
            }
            self.session.stopRunning()   // hand the sensor back to the live preview
            guard !self.frames.isEmpty else { self.finish(error: error?.localizedDescription ?? "No photo"); return }
            do {
                let r = try self.processor.process(frames: self.frames, params: self.params)
                self.frames = []
                self.finish(r)
            } catch {
                self.finish(error: error.localizedDescription)
            }
        }
    }

    private func finish(_ result: [String: Any]) {
        let cb = done
        done = nil
        DispatchQueue.main.async { cb?(result) }
    }

    private func finish(error: String) {
        session.stopRunning()
        finish(["ok": false, "error": error])
    }
}

struct SkyError: LocalizedError {
    let msg: String
    init(_ msg: String) { self.msg = msg }
    var errorDescription: String? { msg }
}

enum PhotoSaver {
    /// Adds an image file (HEIF/JPEG) to the photo library; asks for add-only access the first time.
    static func save(_ data: Data, done: @escaping (Bool, String?) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { done(false, "No permission to add to Photos") }; return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }) { ok, err in DispatchQueue.main.async { done(ok, err?.localizedDescription) } }
        }
    }

    static func saveSync(_ data: Data) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var result = false
        save(data) { ok, _ in result = ok; sem.signal() }
        sem.wait()
        return result
    }
}
