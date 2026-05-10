import Foundation
import CoreML
import Vision
import CoreImage

// MARK: - Logging

class Logger {
    nonisolated(unsafe) static let shared = Logger()
    nonisolated(unsafe) private var fileHandle: FileHandle?

    private init() {
        let logsDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".logs")
        do {
            try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
            
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let fileName = "mlbench_\(formatter.string(from: Date())).log"
            let fileURL = logsDir.appendingPathComponent(fileName)
            
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            fileHandle = try FileHandle(forWritingTo: fileURL)
            
            Swift.print("Log file: \(fileURL.path)")
        } catch {
            Swift.print("Warning: Could not create log file: \(error)")
        }
    }

    func write(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let lines = message.components(separatedBy: .newlines)
        for (idx, line) in lines.enumerated() {
            if idx == lines.count - 1 && line.isEmpty { continue }
            let logLine = "[\(timestamp)] \(line)\n"
            if let data = logLine.data(using: .utf8) {
                try? fileHandle?.write(contentsOf: data)
            }
        }
        try? fileHandle?.synchronize()
    }
}

/// Shadowing the global print to also write to the log file.
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let message = items.map { "\($0)" }.joined(separator: separator)
    Swift.print(message, terminator: terminator)
    Logger.shared.write(message + terminator)
}

// MARK: - CLI Arguments

var imagePath: String = ""
var modelPath: String? = nil
var visionTypes: String? = nil
var iterations: Int = 10
var computeUnit: String = "all"
var resizeMax: Int? = nil

var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--image":
        imagePath = args.popFirst() ?? ""
    case "--model":
        modelPath = args.popFirst()
    case "--vision":
        visionTypes = args.popFirst()
    case "--iterations":
        iterations = Int(args.popFirst() ?? "10") ?? 10
    case "--compute":
        computeUnit = args.popFirst() ?? "all"
    case "--resize":
        resizeMax = Int(args.popFirst() ?? "")
    default:
        imagePath = arg
    }
}

if imagePath.isEmpty {
    print("""
    Usage: mlbench [options] <image_path_or_dir>

    Options:
      --model <path>        CoreML model (.mlmodel, .mlpackage, .mlmodelc)
      --vision <types>      Vision requests (comma-separated):
                              face      - VNDetectFaceLandmarksRequest
                              quality   - VNDetectFaceCaptureQualityRequest
                              saliency  - VNGenerateAttentionBasedSaliencyImageRequest
                              classify  - VNClassifyImageRequest
                              feature   - VNGenerateImageFeaturePrintRequest
                              Example: --vision face,quality,saliency
      --iterations <num>    Number of iterations (default: 10)
      --compute <unit>      all, cpu, gpu, ane (default: all)
      --resize <pixels>     Resize image so that its long edge is at most <pixels>.
                              Simulates preview-resolution analysis (e.g. 1024, 2048).
                              Omit to use the original resolution.

    Examples:
      mlbench --vision face,quality,saliency ../rawbench/SamplePic/
      mlbench --vision face,quality,saliency,classify,feature --iterations 20 ../rawbench/SamplePic/
      mlbench --vision face,quality --resize 1024 --iterations 20 ../rawbench/SamplePic/
      mlbench --model MyModel.mlpackage ../rawbench/SamplePic/
    """)
    exit(1)
}

// MARK: - Image Loading

var imageURLs: [URL] = []
let inputURL = URL(fileURLWithPath: imagePath)

var isDirectory: ObjCBool = false
if FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDirectory) {
    if isDirectory.boolValue {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: inputURL, includingPropertiesForKeys: nil)
            imageURLs = files.filter { ["jpg", "jpeg", "png", "arw", "heic"].contains($0.pathExtension.lowercased()) }
        } catch {
            print("Failed to read directory: \(error)")
            exit(1)
        }
    } else {
        imageURLs = [inputURL]
    }
}

if imageURLs.isEmpty {
    print("No images found at \(imagePath)")
    exit(1)
}

print("Found \(imageURLs.count) images. Will use the first one for iteration benchmark.")
let targetImageURL = imageURLs.first!

guard let imageSource = CGImageSourceCreateWithURL(targetImageURL as CFURL, nil),
      let originalImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    print("Failed to load image at \(targetImageURL.path)")
    exit(1)
}

print("Image loaded: \(targetImageURL.lastPathComponent) (\(originalImage.width)x\(originalImage.height))")

/// Resize a CGImage so that its longest edge is at most `maxDimension` pixels.
func resizedImage(_ source: CGImage, maxDimension: Int) -> CGImage {
    let srcW = source.width
    let srcH = source.height
    let longEdge = max(srcW, srcH)
    guard longEdge > maxDimension else { return source }

    let scale = Double(maxDimension) / Double(longEdge)
    let newW = Int(Double(srcW) * scale)
    let newH = Int(Double(srcH) * scale)

    guard let context = CGContext(
        data: nil,
        width: newW,
        height: newH,
        bitsPerComponent: source.bitsPerComponent,
        bytesPerRow: 0,
        space: source.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: source.bitmapInfo.rawValue
    ) else {
        print("Warning: Failed to create resize context, using original image")
        return source
    }
    context.interpolationQuality = .high
    context.draw(source, in: CGRect(x: 0, y: 0, width: newW, height: newH))
    return context.makeImage() ?? source
}

let cgImage: CGImage
if let resizeMax {
    let start = CFAbsoluteTimeGetCurrent()
    cgImage = resizedImage(originalImage, maxDimension: resizeMax)
    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
    print(String(format: "Resized to %dx%d (max %d) in %.2f ms",
                 cgImage.width, cgImage.height, resizeMax, elapsed))
} else {
    cgImage = originalImage
}

// MARK: - Vision Pipeline Mode

/// Maps a short name to a Vision request and its display label.
func makeVisionRequest(for type: String) -> (request: VNRequest, label: String)? {
    switch type.lowercased().trimmingCharacters(in: .whitespaces) {
    case "face":
        return (VNDetectFaceLandmarksRequest(), "VNDetectFaceLandmarksRequest")
    case "quality":
        return (VNDetectFaceCaptureQualityRequest(), "VNDetectFaceCaptureQualityRequest")
    case "saliency":
        return (VNGenerateAttentionBasedSaliencyImageRequest(), "VNGenerateAttentionBasedSaliencyImageRequest")
    case "classify":
        return (VNClassifyImageRequest(), "VNClassifyImageRequest")
    case "feature":
        return (VNGenerateImageFeaturePrintRequest(), "VNGenerateImageFeaturePrintRequest")
    default:
        print("Unknown vision type: \(type)")
        return nil
    }
}

/// Prints summary statistics for a list of timing samples.
func printStats(label: String, times: [Double]) {
    let sorted = times.sorted()
    let min = sorted.first!
    let max = sorted.last!
    let avg = times.reduce(0, +) / Double(times.count)
    let median = sorted[times.count / 2]
    print(String(format: "  %-45s  Min: %7.2f  Max: %7.2f  Avg: %7.2f  Median: %7.2f ms",
                 (label as NSString).utf8String!, min, max, avg, median))
}

if let visionTypes {
    // --- Vision Pipeline Benchmark ---
    let typeList = visionTypes.split(separator: ",").map(String.init)
    var pipeline: [(request: VNRequest, label: String)] = []

    for t in typeList {
        guard let entry = makeVisionRequest(for: t) else {
            exit(1)
        }
        pipeline.append(entry)
    }

    print("\nVision Pipeline Benchmark")
    print("  Requests: \(pipeline.map(\.label).joined(separator: " + "))")
    print("  Iterations: \(iterations)")
    print("")

    // Per-request timing storage
    var perRequestTimes: [[Double]] = Array(repeating: [], count: pipeline.count)
    var totalTimes: [Double] = []

    for i in 0..<iterations {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        var iterTotal: Double = 0

        // Run each request individually to get per-request timing
        for (idx, entry) in pipeline.enumerated() {
            let perHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            let start = CFAbsoluteTimeGetCurrent()
            do {
                try perHandler.perform([entry.request])
            } catch {
                print("  \(entry.label) failed: \(error)")
                exit(1)
            }
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            perRequestTimes[idx].append(elapsed)
            iterTotal += elapsed
        }

        // Also run all together to measure combined throughput
        let combinedStart = CFAbsoluteTimeGetCurrent()
        do {
            try handler.perform(pipeline.map(\.request))
        } catch {
            print("  Combined pipeline failed: \(error)")
            exit(1)
        }
        let combinedElapsed = (CFAbsoluteTimeGetCurrent() - combinedStart) * 1000.0
        totalTimes.append(combinedElapsed)

        print(String(format: "  Iter %2d:  individual sum = %7.2f ms  |  combined = %7.2f ms",
                     i + 1, iterTotal, combinedElapsed))
    }

    // Results
    print("\n--- Vision Pipeline Results ---")
    print(String(format: "Resolution: %dx%d", cgImage.width, cgImage.height))
    print("")
    print("Per-request breakdown (individual execution):")
    for (idx, entry) in pipeline.enumerated() {
        printStats(label: entry.label, times: perRequestTimes[idx])
    }
    print("")
    print("Combined pipeline (all requests in single perform call):")
    printStats(label: "Combined", times: totalTimes)

    // Print observation summaries for the last iteration
    print("")
    print("Last iteration observation summary:")
    for entry in pipeline {
        let results = entry.request.results ?? []
        switch entry.request {
        case is VNDetectFaceLandmarksRequest:
            let faces = results.compactMap { $0 as? VNFaceObservation }
            print("  \(entry.label): \(faces.count) face(s) detected")
            for (fi, face) in faces.enumerated() {
                let hasLandmarks = face.landmarks != nil
                print("    Face \(fi): confidence=\(String(format: "%.3f", face.confidence)), landmarks=\(hasLandmarks)")
            }
        case is VNDetectFaceCaptureQualityRequest:
            let faces = results.compactMap { $0 as? VNFaceObservation }
            print("  \(entry.label): \(faces.count) face(s)")
            for (fi, face) in faces.enumerated() {
                let quality = face.faceCaptureQuality ?? -1
                print("    Face \(fi): captureQuality=\(String(format: "%.3f", quality))")
            }
        case is VNGenerateAttentionBasedSaliencyImageRequest:
            let obs = results.compactMap { $0 as? VNSaliencyImageObservation }
            print("  \(entry.label): \(obs.count) observation(s)")
            if let first = obs.first {
                let salientObjects = first.salientObjects ?? []
                print("    Salient objects: \(salientObjects.count)")
            }
        case is VNClassifyImageRequest:
            let classifications = results.compactMap { $0 as? VNClassificationObservation }
            let top5 = classifications.prefix(5)
            print("  \(entry.label): \(classifications.count) classification(s), top 5:")
            for c in top5 {
                print("    \(c.identifier): \(String(format: "%.3f", c.confidence))")
            }
        case is VNGenerateImageFeaturePrintRequest:
            let prints = results.compactMap { $0 as? VNFeaturePrintObservation }
            print("  \(entry.label): \(prints.count) feature print(s)")
            if let fp = prints.first {
                print("    Element count: \(fp.elementCount), type: \(fp.elementType.rawValue)")
            }
        default:
            print("  \(entry.label): \(results.count) result(s)")
        }
    }

    print("-------------------------------")

} else {
    // --- Original single-model benchmark ---

    func createRequest(modelPath: String?, computeUnit: String) async throws -> VNRequest {
        if let modelPath = modelPath {
            let modelURL = URL(fileURLWithPath: modelPath)
            print("Loading custom model from \(modelPath)...")
            let start = CFAbsoluteTimeGetCurrent()

            let compiledURL: URL
            if modelURL.pathExtension == "mlmodel" || modelURL.pathExtension == "mlpackage" {
                print("Compiling model...")
                compiledURL = try await MLModel.compileModel(at: modelURL)
            } else {
                compiledURL = modelURL
            }

            let config = MLModelConfiguration()
            switch computeUnit.lowercased() {
            case "cpu": config.computeUnits = .cpuOnly
            case "gpu", "cpuandgpu": config.computeUnits = .cpuAndGPU
            case "ane", "cpuandneuralengine": config.computeUnits = .cpuAndNeuralEngine
            default: config.computeUnits = .all
            }
            print("Compute Units: \(config.computeUnits.rawValue)")

            let model = try await MLModel.load(contentsOf: compiledURL, configuration: config)
            let vnModel = try VNCoreMLModel(for: model)
            let end = CFAbsoluteTimeGetCurrent()
            print(String(format: "Model loaded in %.2f ms", (end - start) * 1000.0))

            return VNCoreMLRequest(model: vnModel)
        } else {
            print("No model provided, using built-in VNClassifyImageRequest as baseline...")
            let request = VNClassifyImageRequest()
            // Force revision if needed, but default is fine for benchmark
            return request
        }
    }

    let request: VNRequest
    do {
        request = try await createRequest(modelPath: modelPath, computeUnit: computeUnit)
    } catch {
        print("Failed to create request: \(error)")
        exit(1)
    }

    // 3. Benchmark Run
    print("Starting benchmark with \(iterations) iterations...")

    var times: [Double] = []

    for i in 0..<iterations {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        let start = CFAbsoluteTimeGetCurrent()
        do {
            try handler.perform([request])
        } catch {
            print("Inference failed: \(error)")
            exit(1)
        }
        let end = CFAbsoluteTimeGetCurrent()

        let durationMs = (end - start) * 1000.0
        times.append(durationMs)
        print(String(format: "Iter %d: %.2f ms", i + 1, durationMs))
    }

    let sortedTimes = times.sorted()
    let minTime = sortedTimes.first!
    let maxTime = sortedTimes.last!
    let avgTime = times.reduce(0, +) / Double(times.count)
    let medianTime = sortedTimes[times.count / 2]

    print("--- Benchmark Results ---")
    if let modelPath = modelPath {
        print("Model: \(URL(fileURLWithPath: modelPath).lastPathComponent)")
    } else {
        print("Model: Built-in VNClassifyImageRequest")
    }
    print(String(format: "Resolution: %dx%d", cgImage.width, cgImage.height))
    print(String(format: "Min:    %.2f ms", minTime))
    print(String(format: "Max:    %.2f ms", maxTime))
    print(String(format: "Avg:    %.2f ms", avgTime))
    print(String(format: "Median: %.2f ms", medianTime))
    print("-------------------------")
}
