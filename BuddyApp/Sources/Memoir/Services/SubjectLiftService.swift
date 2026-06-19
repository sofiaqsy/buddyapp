import UIKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

class SubjectLiftService {

    // Shared context — reused across all subject-lift operations.
    // CIContext init allocates a Metal pipeline; creating one per call adds
    // noticeable latency even on the background thread.
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    func liftSubject(from image: UIImage) async throws -> UIImage {
        guard let cgImage = image.cgImage else { throw LiftError.invalidImage }
        let orientation = image.imageOrientation

        return try await Task.detached(priority: .userInitiated) {
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])

            guard let result = request.results?.first else {
                throw LiftError.noSubjectFound
            }

            let maskBuffer = try result.generateScaledMaskForImage(
                forInstances: result.allInstances,
                from: handler
            )

            return try Self.applyMask(maskBuffer, to: cgImage, orientation: orientation)
        }.value
    }

    private static func applyMask(
        _ mask: CVPixelBuffer,
        to cgImage: CGImage,
        orientation: UIImage.Orientation
    ) throws -> UIImage {
        let original = CIImage(cgImage: cgImage)
        let maskCI = CIImage(cvPixelBuffer: mask)
            .transformed(by: CGAffineTransform(
                scaleX: original.extent.width  / CGFloat(CVPixelBufferGetWidth(mask)),
                y:      original.extent.height / CGFloat(CVPixelBufferGetHeight(mask))
            ))

        let blend = CIFilter.blendWithMask()
        blend.inputImage      = original
        blend.maskImage       = maskCI
        blend.backgroundImage = CIImage.empty()

        guard
            let output = blend.outputImage,
            let result = ciContext.createCGImage(output, from: original.extent)
        else { throw LiftError.maskingFailed }

        return UIImage(cgImage: result, scale: 1.0, orientation: orientation)
    }

    enum LiftError: LocalizedError {
        case invalidImage, noSubjectFound, maskingFailed

        var errorDescription: String? {
            switch self {
            case .invalidImage:   return "Could not read image data."
            case .noSubjectFound: return "No subject detected in this photo."
            case .maskingFailed:  return "Failed to create the sticker cutout."
            }
        }
    }
}
