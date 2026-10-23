// Lifts each demo packshot off its backdrop with Vision, on the Mac.
//
//   swift AppStore/demo/cutout.swift AppStore/demo/catalog AppStore/demo/catalog/cutouts
//
// The app does this itself on a phone (`Cutout.make`), but Vision produces nothing in the
// Simulator — which is where the screenshots are shot — and the generated packshots have a
// soft vignette that `Seamless` rightly refuses as "not a flat sweep". So the stickers are
// made here, with the same request the app uses, and `DemoCatalog` installs them as each
// item's cutout. Output is cropped to the subject, like the app's own.
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let context = CIContext()

let files = try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "jpg" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

for file in files {
    let handler = VNImageRequestHandler(url: file)
    let request = VNGenerateForegroundInstanceMaskRequest()
    try handler.perform([request])
    guard let result = request.results?.first, !result.allInstances.isEmpty else {
        print("no subject:", file.lastPathComponent); continue
    }
    let buffer = try result.generateMaskedImage(
        ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: true
    )
    let image = CIImage(cvPixelBuffer: buffer)
    let out = output.appending(path: file.deletingPathExtension().lastPathComponent + ".png")
    try context.writePNGRepresentation(
        of: image, to: out, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    )
    print(out.lastPathComponent, Int(image.extent.width), "x", Int(image.extent.height))
}
