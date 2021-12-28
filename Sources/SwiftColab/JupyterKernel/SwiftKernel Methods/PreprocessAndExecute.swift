import Foundation
import PythonKit

fileprivate let lldb = Python.import("lldb")
fileprivate let re = Python.import("re")
fileprivate let os = Python.import("os")
fileprivate let sys = Python.import("sys")

func preprocess_and_execute(_ selfRef: PythonObject, code: PythonObject) throws -> Any {
    do {
        let preprocessed = try preprocess(selfRef, code: code)
        return execute(selfRef, code: preprocessed)
    } catch let e as PreprocessorException {
        return PreprocessorError(exception: e)
    }
}

func execute(_ selfRef: PythonObject, code: PythonObject) -> ExecutionResult {
    let fileName = file_name_for_source_location(selfRef)
    let locationDirective = PythonObject("#sourceLocation(file: \(fileName), line: 1)")
    let codeWithLocationDirective = locationDirective + "\n" + code
    
    let result = selfRef.target.EvaluateExpression(
        codeWithLocationDirective, selfRef.expr_opts)
    let errorType = result.error.type
    
    if errorType == lldb.eErrorTypeInvalid {
        return SuccessWithValue(result: result)
    } else if errorType == lldb.eErrorTypeGeneric {
        return SuccessWithoutValue()
    } else {
        return SwiftError(result: result)
    }
}

fileprivate func file_name_for_source_location(_ selfRef: PythonObject) -> String {
    "<Cell \(selfRef.execution_count)>"
}

fileprivate func preprocess(_ selfRef: PythonObject, code: PythonObject) throws -> PythonObject {
    let lines = Array(code[dynamicMember: "split"]("\n"))
    let preprocessed_lines = try (0..<lines.count).map { i -> PythonObject in
        let line = lines[i]
        return try preprocess_line(selfRef, line_index: PythonObject(i), line: line)
    }
    
    return PythonObject("\n").join(preprocessed_lines)
}

/// Returns the preprocessed line.
///
/// Does not process "%install" directives, because those need to be
/// handled before everything else.
fileprivate func preprocess_line(_ selfRef: PythonObject, line_index: PythonObject, line: PythonObject) throws -> PythonObject {
    let include_match = re.match(###"""
    ^\s*%include (.*)$
    """###, line)
    if include_match != Python.None {
        do {
            return try read_include(selfRef, line_index: line_index, rest_of_line: include_match.group(1))
        } catch {
            fatalError("debug checkpoint 0.1")
        }
    }
    
    let disable_completion_match = re.match(###"""
    ^\s*%disableCompletion\s*$
    """###, line)
    if disable_completion_match != Python.None {
        do {
            try handle_disable_completion(selfRef)
        } catch {
            fatalError("debug checkpoint 0.2")
        }
        return ""
    }
    
    let enable_completion_match = re.match(###"""
    ^\s*%enableCompletion\s*$
    """###, line)
    if enable_completion_match != Python.None {
        do {
            try handle_enable_completion(selfRef)
        } catch {
            fatalError("debug checkpoint 0.3")
        }
        return ""
    }
    
    return line
}

fileprivate func read_include(_ selfRef: PythonObject, line_index: PythonObject, rest_of_line: PythonObject) throws -> PythonObject {
    let name_match = re.match(###"""
    ^\s*"([^"]+)"\s*$
    """###, rest_of_line)
    guard name_match != Python.None else {
        throw PreprocessorException(
            "Line \(line_index + 1): %include must be followed by a name in quotes")
    }
    
    let name = name_match.group(1)
    
    let include_paths = [
        os.path.realpath("."),
        PythonObject("/opt/swift/include")
    ]
    var code = Python.None
    
    for include_path in include_paths {
        do {
            let path = os.path.join(include_path, name)
            var f: PythonObject
            
            do {
                f = try Python.open.throwing
                .dynamicallyCall(withArguments: path, "r")
            } catch {
                fatalError("debug checkpoint 0.0.1 --- \(path) --- \(include_path) --- \(String(reflecting: include_paths)) --- \(name) --- \(String(reflecting: error))")
            }
            
            do {
                code = try f.read.throwing.dynamicallyCall(withArguments: [])
            } catch {
                fatalError("debug checkpoint 0.0.2")
            }
            f.close()
        } catch PythonError.exception(let error, let traceback) {
            guard error.__class__ == Python.IOError else {
                throw PythonError.exception(error, traceback: traceback)
            }
        }
    }
    
    guard code != Python.None else {
        throw PreprocessorException(
            "Line \(line_index + 1): Could not find \"\(name)\". Searched \(include_paths).")
    }
    
    let secondName = file_name_for_source_location(selfRef)
    
    return PythonObject("\n").join([
        "#sourceLocation(file: \"\(name)\", line: 1)".pythonObject,
        code,
        "#sourceLocation(file: \"\(secondName)\", line: \(line_index + 1)".pythonObject,
        ""
    ])
}
