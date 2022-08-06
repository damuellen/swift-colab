import Foundation
fileprivate let colab = Python.import("google.colab")
fileprivate let pexpect = Python.import("pexpect")
fileprivate let signal = Python.import("signal")
fileprivate let sys = Python.import("sys")
fileprivate let threading = Python.import("threading")
fileprivate let time = Python.import("time")
fileprivate let zmq = Python.import("zmq")

// Not possible to use Swift GCD in place of Python single-threaded threading 
// here.
let SIGINTHandler = PythonClass(
  "SIGINTHandler",
  superclasses: [threading.Thread],
  members: [
    "__init__": PythonInstanceMethod { args in
      let `self` = args[0]
      threading.Thread.__init__(`self`)
      `self`.daemon = true
      return Python.None
    },
    
    "run": PythonInstanceMethod { _ in
      while true {
        signal.sigwait([signal.SIGINT])
        _ = KernelContext.async_interrupt_process()
        KernelContext.isInterrupted = true
      }
      // Do not need to return anything because this is an infinite loop.
    }
  ]
).pythonObject

// Not possible to use Swift GCD in place of Python single-threaded threading 
// here.
let StdoutHandler = PythonClass(
  "StdoutHandler",
  superclasses: [threading.Thread],
  members: [
    "__init__": PythonInstanceMethod { (`self`: PythonObject) in
      threading.Thread.__init__(`self`)
      `self`.daemon = true
      `self`.had_stdout = false
      return Python.None
    },
    
    "run": PythonInstanceMethod { (`self`: PythonObject) in
      while true {
        time.sleep(0.05)
        if !KernelContext.pollingStdout {
          break
        }
        getAndSendStdout(handler: `self`)
      }
      getAndSendStdout(handler: `self`)
      return Python.None
    }
  ]
).pythonObject

fileprivate var cachedScratchBuffer: UnsafeMutablePointer<CChar>?

fileprivate func getStdout() -> String {
  var stdout = Data()
  let bufferSize = 1 << 16
  let scratchBuffer = cachedScratchBuffer ?? .allocate(capacity: bufferSize)
  cachedScratchBuffer = scratchBuffer
  while true {
    let stdoutSize = KernelContext.get_stdout(scratchBuffer, Int32(bufferSize))
    guard stdoutSize > 0 else {
      break
    }
    let stdoutSegment = Data(
      bytesNoCopy: scratchBuffer, count: Int(stdoutSize), deallocator: .none)
    stdout += stdoutSegment
  }
  return String(data: stdout, encoding: .utf8)!
}

fileprivate func sendStdout(_ stdout: String) {
  if let range = stdout.range(of: "\033[2J") {
    sendStdout(String(stdout[..<range.lowerBound]))
    KernelContext.sendResponse("clear_output", [
      "wait": false
    ])
    sendStdout(String(stdout[range.upperBound...]))
  } else {
    KernelContext.sendResponse("stream", [
      "name": "stdout",
      "text": stdout
    ])
  }
}

fileprivate func getAndSendStdout(handler: PythonObject) {
  var stdout = getStdout()
  if stdout.count > 0 {
    if Bool(handler.had_stdout)! == false {
      // Remove header that signalled that the code successfully compiled.
      let header = "HEADER\r\n"
      precondition(stdout.hasPrefix(header), """
        stdout did not start with the expected header "\(header)". stdout was:
        \(stdout)
        """)
      stdout.removeFirst(header.count)
      handler.had_stdout = true
    }
    sendStdout(stdout)
  }
}

fileprivate var errorStreamEnd: Int = 0

func getStderr(readData: Bool) -> String? {
  let errorFilePointer = fopen("/opt/swift/err", "rb")!
  defer { fclose(errorFilePointer) }
  
  fseek(errorFilePointer, 0, SEEK_END)
  let newErrorStreamEnd = ftell(errorFilePointer)
  let messageSize = newErrorStreamEnd - errorStreamEnd
  defer { errorStreamEnd = newErrorStreamEnd }
  if messageSize == 0 || !readData {
    return nil
  }
  
  let errorDataPointer = malloc(messageSize)!
  fseek(errorFilePointer, errorStreamEnd, SEEK_SET)
  let readBytes = fread(errorDataPointer, 1, messageSize, errorFilePointer)
  precondition(readBytes == messageSize,
    "Did not read the expected number of bytes from stderr")
  
  return String(
    bytesNoCopy: errorDataPointer, length: messageSize, encoding: .utf8, 
    freeWhenDone: true)!
}

// This attempts to replicate the code located at:
// https://github.com/ipython/ipython/blob/master/IPython/utils/_process_posix.py,
//   def system(self, cmd):
//
// Also pulls source code from this file to allow stdin:
// https://github.com/googlecolab/colabtools/blob/main/google/colab/_system_commands.py
func runTerminalProcess(args: [String], cwd: String? = nil) throws -> Int {
  let joinedArgs = args.joined(separator: " ")
  let process = pexpect.spawn("/bin/sh", args: ["-c", joinedArgs], cwd: cwd)
  let flush = sys.stdout.flush
  let patterns = [pexpect.TIMEOUT, pexpect.EOF]
  var outSize: Int = 0
  
  func getBefore() -> PythonObject? {
    let before = process.before
    if before == Python.None {
      return nil
    } else {
      return before
    }
  }
  
  while true {
    var waitTime: Double = 0.05
    if KernelContext.isInterrupted {
      waitTime = 0.2
      process.sendline(Python.chr(3))
      if let count = getBefore()?.count {
        outSize = count
      }
    }
    
    let resIdx = process.expect_list(patterns, waitTime)
    if let before = getBefore() {
      let stdout = String(before[outSize...].decode("utf8", "replace"))!
      if stdout.count > 0 {
        sendStdout(stdout)
      }
      outSize = before.count
    }
    flush()
    
    if KernelContext.isInterrupted {
      process.terminate(force: true)
      throw InterruptException(
        "User interrupted execution during a `%system` command.")
    } else if Int(resIdx)! == 1 {
      break
    }
  }
  sendStdout("\u{1b}[0m")
  
  process.isalive() // Force `exitstatus` to materialize.
  if let exitstatus = Int(process.exitstatus) {
    if exitstatus > 128 {
      return -(exitstatus - 128)
    } else {
      return exitstatus
    }
  } else if let signalstatus = Int(process.signalstatus) {
    return -signalstatus
  } else {
    return 0
  }
}

//===----------------------------------------------------------------------===//
// ColabTools Python code translations
//===----------------------------------------------------------------------===//

fileprivate let _NOT_READY = Python.object()

// Reads the next message from stdin_socket.
fileprivate func _read_next_input_message() -> PythonObject {
  let kernel = KernelContext.kernel
  let stdin_socket = kernel.stdin_socket
  var reply = Python.None

  do {
    reply = try kernel.session.recv.throwing.dynamicallyCall(
      withArguments: stdin_socket, zmq.NOBLOCK)
  } catch {
    // We treat invalid messages as empty replies.
  }
  if reply == Python.None {
    return _NOT_READY
  }

  // We want to return '' even if reply is malformed.
  return reply.get("content", PythonObject([:])).get("value", "")
}

// Reads a stdin message.
fileprivate func _read_stdin_message() -> PythonObject {
  while true {
    let value = _read_next_input_message()
    if Bool(value == _NOT_READY)! {
      return Python.None
    }

    // Skip any colab responses.
    if Bool(Python.isinstance(value, Python.dict))!,
       value.get("type") == "colab_reply" {
      continue
    }
    return value
  }
}

// Reads a reply to the message from the stdin channel.
fileprivate func read_reply_from_input(
  _ message_id: PythonObject,
  _ timeout_sec: PythonObject = Python.None
) -> PythonObject {
  var deadline = Python.None
  if timeout_sec != Python.None {
    deadline = time.time() + timeout_sec
  }
  while deadline == Python.None || time.time() < deadline {
    let reply = _read_next_input_message()
    if reply == _NOT_READY || !Bool(Python.isinstance(reply, Python.dict))! {
      time.sleep(0.025)
      continue
    }
    if reply.get("type") == "colab_reply",
       reply.get("colab_msg_id") == message_id {
      // TODO: Throw an error if `reply` contains 'error'.
      return reply.get("data", Python.None)
    }
  }
  return Python.None
}

// Global counter for message id.
fileprivate var _msg_id: PythonObject = 0

// Sends the given message to the frontend without waiting for a reply.
fileprivate func send_request(
  _ request_type: PythonObject,
  _ request_body: PythonObject,
  _ parent: PythonObject = Python.None,
  _ expect_reply: PythonObject = true
) -> PythonObject {
  var request_id = Python.None
  var metadata = [
    "colab_request_type": request_type
  ].pythonObject
  if Bool(expect_reply)! {
    _msg_id += 1
    request_id = _msg_id
    metadata["colab_msg_id"] = request_id
  }
  var content = [
    "request": request_body
  ].pythonObject

  // If there's no parent message, add in the session header to route to the
  // appropriate frontend.
  var parent_copy = parent
  if parent_copy == Python.None {
    // TODO: Is this the same as `kernel.shell.parent_header`?
    let parent_header = KernelContext.kernel._parent_header
    if parent_header != Python.None {
      parent_copy = [
        "header": [
          // Only specifying the session if it is not a cell-related message.
          "session": parent_header["header"]["session"]
        ].pythonObject
      ].pythonObject
    }
  }
  
  let kernel = KernelContext.kernel
  let msg = kernel.session.msg(
    "colab_request", content: content, metadata: metadata, parent: parent)
  kernel.session.send(kernel.iopub_socket, msg)
  return request_id
}