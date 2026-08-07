import Foundation
import ImageIO
import Vision

guard CommandLine.arguments.count > 1 else { exit(1) }

let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Unable to load image")
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true
request.recognitionLanguages = ["en-US"]

let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
do {
    try handler.perform([request])
} catch {
    fatalError("Vision failed: \(error)")
}

for observation in request.results ?? [] {
    guard let candidate = observation.topCandidates(1).first else { continue }
    let box = observation.boundingBox
    let y = 1.0 - box.origin.y - box.size.height
    print(String(format: "x=%.3f y=%.3f w=%.3f h=%.3f\t%@", box.origin.x, y, box.size.width, box.size.height, candidate.string))
}
