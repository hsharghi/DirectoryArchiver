// swift-tools-version: 5.9
// Cross-platform version that works on macOS, Linux, and Windows
import ArgumentParser
import Foundation

#if os(Windows)
import WinSDK
#endif

@main
struct ArchiveDirectories: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "archive-dirs",
        abstract: "Archive all directories in a specified directory into separate uncompressed tar files",
        discussion: """
        This tool creates individual tar archives for each subdirectory found in the source directory.
        Archives are uncompressed and saved with a .tar extension.
        
        Note: On Windows, this requires tar.exe to be available in PATH (included in Windows 10+).
        
        Examples:
          archive-dirs -d /home/user/projects
          archive-dirs -d C:\\Projects -o C:\\Backups
          archive-dirs --directory ~/Documents --output ~/archives
        """
    )
    
    @Option(name: .shortAndLong, help: "Source directory containing directories to archive")
    var directory: String
    
    @Option(name: .shortAndLong, help: "Output directory for tar files (default: same as source directory)")
    var output: String?
    
    mutating func run() throws {
        let fileManager = FileManager.default
        
        // Expand and resolve source directory path
        let sourcePath = expandPath(directory)
        let sourceURL = URL(fileURLWithPath: sourcePath)
        
        // Validate source directory
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw ValidationError("Source directory '\(sourcePath)' does not exist or is not accessible.")
        }
        
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ValidationError("Source path '\(sourcePath)' is not a directory.")
        }
        
        guard fileManager.isReadableFile(atPath: sourceURL.path) else {
            throw ValidationError("Cannot read source directory '\(sourcePath)'. Permission denied.")
        }
        
        // Determine output directory
        let outputPath: String
        let outputURL: URL
        
        if let output = output {
            outputPath = expandPath(output)
            outputURL = URL(fileURLWithPath: outputPath)
            print("Output directory specified: \(outputPath)")
        } else {
            outputPath = sourcePath
            outputURL = sourceURL
            print("Output directory not specified. Using source directory: \(sourcePath)")
        }
        
        // Create output directory if needed
        if !fileManager.fileExists(atPath: outputURL.path) {
            print("Output directory '\(outputPath)' does not exist. Creating it...")
            do {
                try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
                print("Created output directory: \(outputPath)")
            } catch {
                throw ValidationError("Failed to create output directory '\(outputPath)': \(error.localizedDescription)")
            }
        }
        
        guard fileManager.isWritableFile(atPath: outputURL.path) else {
            throw ValidationError("Cannot write to output directory '\(outputPath)'. Permission denied.")
        }
        
        // Get absolute paths
        let sourceAbsPath = sourceURL.standardized.path
        let outputAbsPath = outputURL.standardized.path
        let sameDirectory = sourceAbsPath == outputAbsPath
        
        if sameDirectory {
            print("Note: Output directory is same as source directory.")
        }
        
        print("========================================")
        print("Archive Configuration:")
        print("========================================")
        print("Source directory: \(sourceAbsPath)")
        print("Output directory: \(outputAbsPath)")
        print("")
        
        // Check if tar is available
        guard isTarAvailable() else {
            throw ValidationError("tar command not found. Please ensure tar is installed and in your PATH.")
        }
        
        // Find all subdirectories
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: sourceURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw ValidationError("Failed to read source directory: \(error.localizedDescription)")
        }
        
        let directories = contents.filter { url in
            guard let isDir = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory else {
                return false
            }
            return isDir
        }
        
        guard !directories.isEmpty else {
            print("No directories found in source directory.")
            return
        }
        
        let totalDirs = directories.count
        print("Found \(totalDirs) director\(totalDirs == 1 ? "y" : "ies") to archive.")
        print("")
        
        // Process each directory
        var successCount = 0
        var failCount = 0
        var skipCount = 0
        
        for (index, dirURL) in directories.enumerated() {
            let current = index + 1
            let dirName = dirURL.lastPathComponent
            let tarFileName = "\(dirName).tar"
            let outputTarURL = outputURL.appendingPathComponent(tarFileName)
            
            print("[\(current)/\(totalDirs)] Processing: \(dirName)")
            
            // Check if archive already exists
            if fileManager.fileExists(atPath: outputTarURL.path) {
                print("  ⚠️  Archive already exists in output directory: \(tarFileName)")
                print("  Skipping...")
                skipCount += 1
                print("")
                continue
            }
            
            // Create tar archive
            print("  Creating: \(outputTarURL.path)")
            
            let success = createTarArchive(
                sourceDir: sourceURL,
                targetDir: dirName,
                outputFile: outputTarURL
            )
            
            if success {
                // Get file size
                if let attributes = try? fileManager.attributesOfItem(atPath: outputTarURL.path),
                   let fileSize = attributes[.size] as? Int64 {
                    let sizeString = formatFileSize(fileSize)
                    print("  ✓ Created: \(tarFileName) (\(sizeString))")
                } else {
                    print("  ✓ Created: \(tarFileName)")
                }
                successCount += 1
            } else {
                print("  ✗ Failed to create archive for: \(dirName)")
                // Clean up failed tar file
                try? fileManager.removeItem(at: outputTarURL)
                failCount += 1
            }
            
            print("")
        }
        
        // Summary
        print("========================================")
        print("Archiving Summary:")
        print("========================================")
        print("Source directory: \(sourceAbsPath)")
        print("Output directory: \(outputAbsPath)")
        print("Total directories found: \(totalDirs)")
        print("Successfully archived: \(successCount)")
        print("Failed: \(failCount)")
        print("Skipped (already exists): \(skipCount)")
        print("----------------------------------------")
        
        if successCount > 0 {
            print("")
            print("Archives created in: \(outputAbsPath)")
            print("File format: directory_name.tar (uncompressed)")
            
            // List created archives
            print("")
            print("Created archives:")
            
            do {
                let tarFiles = try fileManager.contentsOfDirectory(at: outputURL, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "tar" }
                    .map { $0.lastPathComponent }
                    .sorted()
                
                for fileName in tarFiles.prefix(20) {
                    print(fileName)
                }
                
                if tarFiles.count > 20 {
                    print("... and \(tarFiles.count - 20) more")
                }
            } catch {
                print("(Unable to list archives)")
            }
        }
        
        print("")
        print("Done!")
    }
    
    private func expandPath(_ path: String) -> String {
        #if os(Windows)
        // Windows doesn't use tilde expansion the same way
        if path.starts(with: "~") {
            let home = ProcessInfo.processInfo.environment["USERPROFILE"] ?? ""
            return path.replacingOccurrences(of: "~", with: home)
        }
        return path
        #else
        return NSString(string: path).expandingTildeInPath
        #endif
    }
    
    private func isTarAvailable() -> Bool {
        let process = Process()
        
        #if os(Windows)
        process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\tar.exe")
        #else
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["tar"]
        #endif
        
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
    
    private func createTarArchive(sourceDir: URL, targetDir: String, outputFile: URL) -> Bool {
        let process = Process()
        
        #if os(Windows)
        // Windows 10+ includes tar.exe
        process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\tar.exe")
        process.arguments = ["-cf", outputFile.path, "-C", sourceDir.path, targetDir]
        #else
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cf", outputFile.path, "-C", sourceDir.path, targetDir]
        #endif
        
        // Suppress output
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = Double(bytes)
        var unitIndex = 0
        
        while size >= 1024 && unitIndex < units.count - 1 {
            size /= 1024
            unitIndex += 1
        }
        
        if unitIndex == 0 {
            return "\(Int(size)) \(units[unitIndex])"
        } else {
            return String(format: "%.1f %@", size, units[unitIndex])
        }
    }
}

extension ArchiveDirectories {
    struct ValidationError: LocalizedError {
        let message: String
        
        init(_ message: String) {
            self.message = message
        }
        
        var errorDescription: String? {
            "Error: \(message)"
        }
    }
}