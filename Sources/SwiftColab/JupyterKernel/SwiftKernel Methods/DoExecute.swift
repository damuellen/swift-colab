import Foundation
import PythonKit

fileprivate let json = Python.import("json")
fileprivate let lldb = Python.import("lldb")

func do_execute(_ kwargs: PythonObject) throws -> PythonObject {
    let selfRef = kwargs["self"]
    
    if !Bool(kwargs["silent"])! {
        let stream_content: PythonObject = ["name": "stdout", "text": kwargs["code"]]
        
        let throwingObject = selfRef.send_response.throwing
        try throwingObject.dynamicallyCall(withArguments: selfRef.iopub_socket, "stream", stream_content)
    }
    
    return [
        "status": "ok",
        // The base class increments the execution count
        "execution_count": selfRef.execution_count,
        "payload": [],
        "user_expressions": [:],
    ]
}

fileprivate struct Exception: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

fileprivate func after_successful_execution(_ selfRef: PythonObject) throws {
    let result = execute(selfRef, code:
                         "JupyterKernel.communicator.triggerAfterSuccessfulExecution()")
    guard let result = result as? SuccessWithValue else {
        selfRef.log.error(
            "Expected value from triggerAfterSuccessfulExecution(), " +
            "but got: \(result)")
        return
    }
    
    let messages = try read_jupyter_messages(selfRef, result.result)
    try send_jupyter_messages(selfRef, messages)
}

fileprivate func read_jupyter_messages(_ selfRef: PythonObject, _ sbvalue: PythonObject) throws -> PythonObject {
    ["display_messages": try sbvalue.map { 
        display_message_sbvalue in try read_display_message(selfRef, display_message_sbvalue)
    }].pythonObject
}

fileprivate func read_display_message(_ selfRef: PythonObject, _ sbvalue: PythonObject) throws -> PythonObject {
    try sbvalue.map { part in try read_byte_array(selfRef, part) }.pythonObject
}

fileprivate func read_byte_array(_ selfRef: PythonObject, _ sbvalue: PythonObject) throws -> PythonObject {
    let get_address_error = lldb.SBError()
    let address = sbvalue
        .GetChildMemberWithName("address")
        .GetData()
        .GetAddress(get_address_error, 0)
    if Bool(get_address_error.Fail())! {
        throw Exception("getting address: \(get_address_error)")
    }
    
    let get_count_error = lldb.SBError()
    let count_data = sbvalue
        .GetChildMemberWithName("count")
        .GetData()
    var count: PythonObject
    
    switch Int(selfRef._int_bitwidth)! {
    case 32: count = count_data.GetSignedInt32(get_count_error, 0)
    case 64: count = count_data.GetSignedInt64(get_count_error, 0)
    default:
        throw Exception("Unsupported integer bitwidth: \(selfRef._int_bitwidth)")
    }
    if Bool(get_count_error.Fail())! {
        throw Exception("getting count: \(get_count_error)")
    }
    
    // ReadMemory requires that count is positive, so early-return an empty
    // byte array when count is 0.
    if count == 0 {
        return Python.bytes()
    }
    
    let get_data_error = lldb.SBError()
    let data = selfRef.process.ReadMemory(address, count, get_data_error)
    if Bool(get_data_error.Fail())! {
        throw Exception("getting data: \(get_data_error)")
    }
    
    return data
}

fileprivate func send_jupyter_messages(_ selfRef: PythonObject, _ messages: PythonObject) throws {
    let function = selfRef.iopub_socket.send_multipart.throwing
    for display_message in messages["display_messages"] {
        try function.dynamicallyCall(withArguments: display_message)
    }
}

fileprivate func set_parent_message(_ selfRef: PythonObject) throws {
    let jsonDumps = json.dumps(json.dumps(squash_dates(selfRef._parent_header)))
    let result = execute(selfRef, code: """
                         JupyterKernel.communicator.updateParentMessage(
                             to: KernelCommunicator.ParentMessage(json: \(jsonDumps)))
                         """)
    if result is ExecutionResultError {
        throw Exception("Error setting parent message: \(result)")
    }
}

fileprivate func get_pretty_main_thread_stack_trace(_ selfRef: PythonObject) -> [PythonObject] {
    var stack_trace: [PythonObject] = []
    for frame in selfRef.main_thread {
        // Do not include frames without source location information. These
        // are frames in libraries and frames that belong to the LLDB
        // expression execution implementation.
        guard let file = Optional(frame.line_entry.file) else {
            continue
        }
        
        // Do not include <compiler-generated> frames. These are
        // specializations of library functions.
        guard file.fullpath != "<compiler-generated>" else {
            continue
        }
        
        stack_trace.append(Python.str(frame))
    }
    
    return stack_trace
}
