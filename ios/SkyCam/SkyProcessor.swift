import CoreImage
import UIKit
import Vision

/// Turns bracketed frames into the finished photo, in linear float light:
/// align → merge to HDR → crop to the chosen frame shape → GND filters + white balance + sky look (same maths as the
/// web preview shader) → cloud detail → HEIF saved to Photos, plus a small JPEG copy for the in-app album.
final class SkyProcessor {
    private let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                          .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
    private lazy var kernels: (merge: CIColorKernel, grade: CIColorKernel)? = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url),
              let m = try? CIColorKernel(functionName: "skyMerge", fromMetalLibraryData: data),
              let g = try? CIColorKernel(functionName: "skyGrade", fromMetalLibraryData: data) else { return nil }
        return (m, g)
    }()

    func process(frames: [(data: Data, bias: Float)], params: [String: Any]) throws -> [String: Any] {
        guard let k = kernels else { throw SkyError("Image kernels missing") }
        let ev = Float(num(params["ev"]))
        let imgs = frames.compactMap { f -> (img: CIImage, bias: Float)? in
            guard let i = CIImage(data: f.data, options: [.applyOrientationProperty: true]) else { return nil }
            let o = i.transformed(by: CGAffineTransform(translationX: -i.extent.minX, y: -i.extent.minY))
            return (o, f.bias)
        }.sorted { $0.bias < $1.bias }
        guard !imgs.isEmpty else { throw SkyError("Could not read photo") }

        // Each frame is scaled to the user's exposure: a frame shot at bias b is 2^(ev−b) away from it.
        let gainFor = { (b: Float) -> Float in pow(2, ev - b) }
        var image: CIImage
        if imgs.count >= 3 {
            let mid = imgs[imgs.count / 2], dark = imgs.first!, bright = imgs.last!
            let kd = gainFor(dark.bias), km = gainFor(mid.bias), kb = gainFor(bright.bias)
            let d = align(dark.img, k: kd, to: mid.img, km: km), b = align(bright.img, k: kb, to: mid.img, km: km)
            guard let merged = k.merge.apply(extent: mid.img.extent,
                                             arguments: [d, mid.img, b, kd, km, kb]) else { throw SkyError("Merge failed") }
            image = merged
        } else {
            image = imgs[0].img
        }

        // Crop to the frame shape (and the 2× centre crop) the preview showed
        let ratio = CGFloat(num(params["ratio"], 0.75)), zoom = CGFloat(max(1, num(params["zoom"], 1)))
        let E = image.extent
        var cw = E.width, ch = E.height
        if cw / ch > ratio { cw = ch * ratio } else { ch = cw / ratio }
        cw /= zoom; ch /= zoom
        let crop = CGRect(x: (E.width - cw) / 2, y: (E.height - ch) / 2, width: cw, height: ch).integral
        image = image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let W = crop.width, H = crop.height

        // GND filters: A = (cx, cy, nx, ny), B = (stops, transition, type, 0), C = colour; same layout as the web shader
        let gnd = (params["gnd"] as? [[String: Any]]) ?? []
        let types = ["soft": 0.0, "hard": 1.0, "rev": 2.0]
        let cols: [String: [Double]] = ["n": [1, 1, 1], "blue": [0.74, 0.93, 1.36], "sun": [1.32, 0.92, 0.6],
                                        "tob": [1.16, 0.93, 0.66], "mag": [1.2, 0.78, 1.14]]
        var A: [CIVector] = [], B: [CIVector] = [], C: [CIVector] = []
        for i in 0..<5 {
            if i < gnd.count {
                let g = gnd[i], a = num(g["a"]) * .pi / 180
                A.append(CIVector(x: num(g["cx"], 0.5), y: num(g["cy"], 0.5), z: sin(a), w: -cos(a)))
                B.append(CIVector(x: num(g["st"], 2), y: num(g["f"], 0.18), z: types[g["ty"] as? String ?? "soft"] ?? 0, w: 0))
                let c = cols[g["col"] as? String ?? "n"] ?? [1, 1, 1], l = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
                C.append(CIVector(x: c[0] / l, y: c[1] / l, z: c[2] / l))
            } else {
                A.append(CIVector(x: 0, y: 0, z: 0, w: -1)); B.append(CIVector(x: 0, y: 0, z: 0, w: 0)); C.append(CIVector(x: 1, y: 1, z: 1))
            }
        }
        let look = (params["look"] as? [String: Any]) ?? [:]
        let wbArr = (params["wb"] as? [Any])?.map { num($0, 1) } ?? [1, 1, 1]
        let wb = CIVector(x: wbArr[0], y: wbArr.count > 1 ? wbArr[1] : 1, z: wbArr.count > 2 ? wbArr[2] : 1)
        let l1 = CIVector(x: num(look["con"]), y: num(look["haze"]), z: num(look["vib"]), w: num(look["cpl"]))
        let l2 = CIVector(x: num(look["sh"]), y: num(look["hi"]), z: num(look["mono"]), w: 0)
        var args: [Any] = [image, CIVector(x: W, y: H), Float(min(5, gnd.count))]
        args += A as [Any]; args += B as [Any]; args += C as [Any]
        args += [wb, l1, l2]
        guard var out = k.grade.apply(extent: image.extent, arguments: args) else { throw SkyError("Grade failed") }

        // Cloud detail = wide unsharp mask (local contrast), sized to the photo like the preview's ring blur
        let cla = num(params["cla"])
        if cla > 0 {
            out = out.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: min(W, H) * 0.018,
                                                                   kCIInputIntensityKey: cla * 0.55])
        }
        out = out.cropped(to: CGRect(x: 0, y: 0, width: W, height: H))

        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!, srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let opts = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92]
        let full = ctx.heifRepresentation(of: out, format: .RGBA8, colorSpace: p3, options: opts)
            ?? ctx.jpegRepresentation(of: out, colorSpace: p3, options: opts)
        guard let fullData = full else { throw SkyError("Encode failed") }
        let saved = PhotoSaver.saveSync(fullData)

        let s = 1600 / max(W, H)
        let small = s < 1 ? out.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1]) : out
        let pv = ctx.jpegRepresentation(of: small, colorSpace: srgb,
                                        options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.85])
        return ["ok": true, "preview": pv?.base64EncodedString() ?? "", "width": Int(W), "height": Int(H),
                "frames": imgs.count, "saved": saved]
    }

    /// Lines a bracket frame up with the reference (hand shake between frames), compared at matched brightness.
    private func align(_ img: CIImage, k: Float, to ref: CIImage, km: Float) -> CIImage {
        let scale = 1024 / max(ref.extent.width, ref.extent.height)
        let prep = { (i: CIImage, g: Float) -> CIImage in
            let gv = CGFloat(g)
            return i.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gv, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: gv, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gv, w: 0)])
                .applyingFilter("CIColorClamp")
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let req = VNTranslationalImageRegistrationRequest(targetedCIImage: prep(img, k), options: [:])
        let handler = VNImageRequestHandler(ciImage: prep(ref, km), options: [:])
        guard (try? handler.perform([req])) != nil,
              let obs = req.results?.first as? VNImageTranslationAlignmentObservation else { return img }
        let t = obs.alignmentTransform
        guard abs(t.tx) < 60, abs(t.ty) < 60 else { return img }   // implausible jump: keep the frame as shot
        return img.transformed(by: CGAffineTransform(translationX: t.tx / scale, y: t.ty / scale))
            .clampedToExtent().cropped(to: ref.extent)
    }
}
