import Foundation

func formatString(_ input: String, ansiOptions: [Int]) -> String {
  var formatSequence = "\u{1b}[0"
  for option in ansiOptions {
    formatSequence += ";\(option)"
  }
  formatSequence += "m"
  let clearSequence = "\u{1b}[0m"
  return formatSequence + input + clearSequence
}

func fetchStderr(errorSource: inout String?) -> [String] {
  guard let stderr = getStderr(readData: true) else {
    return []
  }
  var lines = stderr.split(separator: "\n", omittingEmptySubsequences: false)
    .map(String.init)
  guard let stackTraceIndex = lines.lastIndex(of: "Current stack trace:") else {
    KernelContext.log("failure 1"); return lines
  }
  
  // Return early if there is no error message.
  guard stackTraceIndex > 0 else { KernelContext.log("failure 2"); return lines }
  lines.removeLast(lines.count - stackTraceIndex)
  
  // Remove the "__lldb_expr_NUM/<Cell NUM>:NUM: " prefix to the error message.
  let firstLine = lines[0]
  guard let slashIndex = firstLine.firstIndex(of: "/"), 
        slashIndex > firstLine.startIndex else { 
    KernelContext.log("failure 3"); return lines 
  }
  var moduleName: String?
  if !firstLine.hasPrefix("__lldb_expr_") { 
    moduleName = String(firstLine[..<slashIndex])
  }
  
  var numColons = 0
  var firstColonIndex: String.Index?
  var secondColonIndex: String.Index?
  for index in firstLine[slashIndex...].indices {
    if firstLine[index] == ":" {
      numColons += 1
    }
    if numColons == 1 && firstColonIndex == nil {
      firstColonIndex = index
    } else if numColons == 2 {
      secondColonIndex = index
      break
    }
  }
  guard let firstColonIndex = firstColonIndex, 
        let secondColonIndex = secondColonIndex else { KernelContext.log("failure 4"); return lines }
  
  let fileNameStartIndex = firstLine.index(after: slashIndex)
  var errorFile = String(firstLine[fileNameStartIndex..<firstColonIndex])
  if let moduleName = moduleName {
    errorFile = "\(moduleName)/\(errorFile)"
  }
  errorFile = formatString(errorFile, ansiOptions: [32])
  
  // The substring ends at the character right before the second colon. This
  // means the source location does not include a column.
  let errorLineStartIndex = firstLine.index(after: firstColonIndex)
  var errorLine = String(firstLine[errorLineStartIndex..<secondColonIndex])
  guard Int(errorLine) != nil else { KernelContext.log("failure 5"); return lines }
  errorLine = formatString(errorLine, ansiOptions: [32])
  errorSource = "\(errorFile), Line \(errorLine)"
  
  // The line could theoretically end right after the second colon.
  let messageStartIndex = firstLine.index(secondColonIndex, offsetBy: 2)
  guard firstLine.indices.contains(messageStartIndex) else { KernelContext.log("failure 6"); return lines }
  
  // The error message may span multiple lines, so just modify the first line
  // in-place and return the array.
  lines[0] = colorizeErrorMessage(String(firstLine[messageStartIndex...]))
  return lines
}

fileprivate func colorizeErrorMessage(_ message: String) -> String {
  var colonIndex: String.Index?
  for index in message.indices {
    if message[index] == ":" {
      colonIndex = index
      break
    }
  }
  guard let colonIndex = colonIndex else {
    return message
  }
  
  let labelPortion = formatString(
    String(message[...colonIndex]), ansiOptions: [31])
  let contentsStartIndex = message.index(after: colonIndex)
  return labelPortion + String(message[contentsStartIndex...])
}

func prettyPrintStackTrace(errorSource: String?) throws -> [String] {
  var frames: UnsafeMutablePointer<UnsafeMutableRawPointer>?
  var size: Int32 = 0
  let error = KernelContext.get_pretty_stack_trace(&frames, &size);
  guard let frames = frames else {
    throw Exception(
      "`get_pretty_stack_trace` failed with error code \(error).")
  }
  defer { free(frames) }
  
  // Show where the error originated, regardless of whether there are stack 
  // frames.
  var output: [String] = []
  if let errorSource = errorSource {
    output.append("Location: \(errorSource)")
  }
  if size == 0 {
    output.append("Stack trace not available")
    return output
  } else {
    output.append("Current stack trace:")
  }
  
  // Number of characters, including digits and spaces, before a function name.
  let padding = 5
  for i in 0..<Int(size) {
    let frameBytes = frames[i]
    defer { free(frameBytes) }
    
    let header = frameBytes.assumingMemoryBound(to: UInt32.self)
    let line = formatString("\(header[0])", ansiOptions: [32])
    let column = formatString("\(header[1])", ansiOptions: [32])
    
    var data = frameBytes.advanced(by: 8).assumingMemoryBound(to: CChar.self)
    func extractComponent() -> String {
      let output = String(cString: UnsafePointer(data))
      data += output.count + 1
      return output
    }
    
    let function = formatString(extractComponent(), ansiOptions: [34])
    let file = extractComponent()
    let directory = extractComponent()
    var path: String
    
    if let package = extractPackage(fromPath: directory) {
      // File is in a package's build checkouts
      path = package + "/" + file
    } else if directory.count > 0 {
      // File location not recognized
      path = directory + "/" + file
    } else {
      // File is a notebook cell
      path = file
    }
    path = formatString(path, ansiOptions: [32])
    
    var frameID = String(i + 1) + " "
    if frameID.count < padding {
      frameID += String(
        repeating: " " as Character, count: padding - frameID.count)
    }
    output.append(
      "\(frameID)\(function) - \(path), Line \(line), Column \(column)")
  }
  return output
}
  
fileprivate func extractPackage(fromPath path: String) -> String? {
  // Should never start with the symbolic link "/opt/swift/install-location".
  // Rather, it should start with that link's destination.
  guard path.hasPrefix(KernelContext.installLocation) else {
    return nil
  }
  var url = path.dropFirst(KernelContext.installLocation.count)
  guard url.hasPrefix("/") else { return nil }
  url = url.dropFirst(1)
  
  return String(url)
  // continue later
  
//   // Drop package ID
//   let id = url.prefix(while: { $0.isHexDigit && !$0.isLetter })
}
