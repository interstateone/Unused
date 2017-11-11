import Files
import SourceKittenFramework
import CoreGraphics // canary
import Foundation
import UnusedCore

// SwiftPM
import Basic
import Build
import Commands
import PackageGraph
import PackageLoading
import PackageModel
import Utility
import Workspace

private extension TargetDescription {

    /// The compiler arguments that will be sent to SourceKit.
    ///
    /// In the future, this may or may not be added to `libSwiftPM`.
    var arguments: [String] {
        switch self {
        case .clang(let c):
            return c.basicArguments()
        case .swift(let s):
            return s.compileArguments()
        }
    }

}

/// A module, typically defined and managed by [SwiftPM](), that manages the sources and the compiler arguments
/// that should be sent to SourceKit.
struct SwiftModule: Equatable, Hashable {
    /// The name of the Swift module.
    let name: String

    var sources: [Files.File]

    /// The raw arguments provided by SwiftPM.
    let otherArguments: [String]

    /// Arguments to be sent to SourceKit.
    var arguments: [String] {
      return sources.map({ $0.path }) + otherArguments
    }

    // These need to be massaged a bit for indexing
    var indexingArguments: [String] {
      var args = arguments

      // If the .build/debug symlink in the module cache path isn't resolved to the target's directory, SourceKit will say it can't find the primary source file
      if let index = args.index(of: "-module-cache-path"), args.count > index + 1 {
        args[index + 1] = resolveSymlinks(AbsolutePath(args[index + 1])).asString
      }

      // Need to add the module name, which isn't normally included in compile args, in order to create namespaced USRs
      return args + ["-module-name", name]
    }

    /// Create a module from the definition provided by SwiftPM.
    ///
    /// - Parameters:
    ///   - target: A fully resolved target. All the dependencies for the target are resolved.
    ///   - description: The description of either a Swift or Clang target.
    init(target: ResolvedTarget, description: TargetDescription) {
      name = target.name
      sources = target.sources.paths.lazy
        .flatMap { absolutePath in
          return try? Files.File(path: absolutePath.asString)
        }
      otherArguments = description.arguments
    }

    static func == (lhs: SwiftModule, rhs: SwiftModule) -> Bool {
        return lhs.name == rhs.name
    }

    var hashValue: Int {
        return name.hashValue
    }
}

class ToolWorkspaceDelegate: WorkspaceDelegate {
    func packageGraphWillLoad(currentGraph: PackageGraph, dependencies: AnySequence<ManagedDependency>, missingURLs: Set<String>) { }
    func fetchingWillBegin(repository: String) { }
    func fetchingDidFinish(repository: String, diagnostic: Diagnostic?) { }
    func repositoryWillUpdate(_ repository: String) { }
    func repositoryDidUpdate(_ repository: String) { }
    func cloning(repository: String) { }
    func checkingOut(repository: String, atReference: String, to path: AbsolutePath) { }
    func removing(repository: String) { }
    func managedDependenciesDidUpdate(_ dependencies: AnySequence<ManagedDependency>) { }
}

/// Find the bin directory that contains the Swift compiler.
///
/// - Warning: This is only really working on macOS.
///
/// - Returns: The absolute path to the bin directory containing the Swift compiler.
func findBinDirectory() -> AbsolutePath {
  let whichSwiftcArgs = ["xcrun", "--find", "swiftc"]
  // No value in env, so search for `clang`.
let foundPath = (try? Process.checkNonZeroExit(arguments: whichSwiftcArgs).chomp()) ?? ""
  guard !foundPath.isEmpty else {
    // If `xcrun` fails just use a "default"; still might not work.
    return AbsolutePath("/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin")
  }
  return AbsolutePath(foundPath).parentDirectory
}

let path = AbsolutePath(Folder.current.path)
let buildPath = path.appending(component: ".build")
let edit = path.appending(component: "Packages")
let pins = path.appending(component: "Package.resolved")
let binDirectory = findBinDirectory()
let destination = try! Destination.hostDestination(binDirectory)
let toolchain = try! UserToolchain(destination: destination)
let manifestLoader = ManifestLoader(resources: toolchain.manifestResources)
let delegate = ToolWorkspaceDelegate()
let ws = Workspace(dataPath: buildPath, editablesPath: edit, pinsFile: pins, manifestLoader: manifestLoader, delegate: delegate)
let root = WorkspaceRoot(packages: [path])
let engine = DiagnosticsEngine()
let pg = ws.loadPackageGraph(root: root, diagnostics: engine)
let buildFlags = BuildFlags()
let parameters = BuildParameters(dataPath: buildPath, configuration: .debug, toolchain: toolchain, flags: buildFlags)
let plan = try! BuildPlan(buildParameters: parameters, graph: pg)
var modules = Set(plan.targetMap.map { SwiftModule(target: $0.key, description: $0.value) })
  .filter { $0.name == "UnusedCore" || $0.name == "Unused" }

struct FileIndex {
  let file: Files.File
  let index: [[String: SourceKitRepresentable]]
}

struct Declaration: Hashable {
  let file: Files.File
  let line: Int64
  let column: Int64
  let name: String
  let usr: String

  var warning: String {
    return "\(file.path):\(line):\(column): warning: \(name) is unused."
  }

  static func == (lhs: Declaration, rhs: Declaration) -> Bool {
    return lhs.usr == rhs.usr
  }

  var hashValue: Int {
    return usr.hashValue
  }
}

func declarationUSRs(in dictionary: [String: SourceKitRepresentable], of file: Files.File) -> [Declaration] {
  if let kind = dictionary["key.kind"] as? String,
     kind.hasPrefix("source.lang.swift.decl"),
     let USR = dictionary["key.usr"] as? String,
     let name = dictionary["key.name"] as? String,
     let line = dictionary["key.line"] as? Int64,
     let column = dictionary["key.column"] as? Int64 {
    return [Declaration(file: file, line: line, column: column, name: name, usr: USR)]
  }

  return (dictionary["key.entities"] as? [SourceKitRepresentable])?
    .map { $0 as! [String: SourceKitRepresentable] }
    .flatMap { declarationUSRs(in: $0, of: file) } ?? []
}

func uses(of declaration: Declaration, in dictionary: [String: SourceKitRepresentable]) -> [(line: Int, column: Int)] {
  let usr = declaration.usr
  if dictionary["key.usr"] as? String == usr,
    let line = dictionary["key.line"] as? Int64,
    let column = dictionary["key.column"] as? Int64 {
    return [(Int(line - 1), Int(column))]
  }
  return (dictionary["key.entities"] as? [SourceKitRepresentable])?
    .map { $0 as! [String: SourceKitRepresentable] }
    .flatMap { uses(of: declaration, in: $0) } ?? []
}

func countUsage(of USRs: [Declaration], in indexes: [FileIndex]) throws -> [Declaration: Int] {
  let USRUsageCount = indexes.flatMap { fileIndex in
    fileIndex.index.flatMap { entity in
      USRs.map { ($0, uses(of: $0, in: entity).count) }
    }
  }
  return Dictionary(USRUsageCount) { first, second in first + second }
}

func canary() {}
UnusedCore.canary2()
A()

print("files")
modules.forEach { module in
  print(module.name)
  print(module.indexingArguments)
  module.sources.forEach { file in
    print(file.path)
  }
}
print("---")

let allIndexes = modules.flatMap { module -> [FileIndex] in
  return module.sources.flatMap { file -> FileIndex? in
    let request = Request.index(file: file.path, arguments: module.indexingArguments)
    do {
      let result = try request.failableSend()
      print(result)
      let index = result["key.entities"] as! [[String: SourceKitRepresentable]]
      return FileIndex(file: file, index: index)
    } catch {
      print(error)
      return nil
    }
  }
}

let allDeclarationUSRs = allIndexes.flatMap { fileIndex in
  fileIndex.index.flatMap { entity in
    declarationUSRs(in: entity, of: fileIndex.file)
  }
}
print("declarationUSRs")
print(allDeclarationUSRs)
print("---")

let unusedUSRs = try countUsage(of: allDeclarationUSRs, in: allIndexes)
  .filter { key, value in value == 1 }
  .map { key, value in key } // .keys segfaults!?
unusedUSRs.forEach { print($0.warning) }
