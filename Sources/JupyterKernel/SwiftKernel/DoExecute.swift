import Foundation
fileprivate let json = Python.import("json")
fileprivate let jsonutil = Python.import("jupyter_client").jsonutil

internal var doExecute_lock: Bool = false
internal var globalHad_stdout: Bool = false
internal let syncQueue = DispatchQueue(label: "com.swift-colab.syncQueue")

func doExecute(code: String) throws -> PythonObject? {
  syncQueue.sync {
    doExecute_lock = false
    globalHad_stdout = false
  }
  
  // Start up a new thread to collect stdout.
//   let stdoutHandler = StdoutHandler()
//   stdoutHandler.start()
//   stdoutHandler.stop_event.clear()
//   stdoutHandler.stop_event.wait(timeout: 0.1)
  
  let semaphore = DispatchSemaphore(value: 0)
  
  DispatchQueue.global().async {
    var localHad_stdout = false
    
    while true {
      usleep(100_000)
      let doExecute_lock_ret = syncQueue.sync {
        return doExecute_lock
      }
      if doExecute_lock_ret {
        break
      }
      altGetAndSendStdout(hadStdout: &localHad_stdout)
    }
    
    altGetAndSendStdout(hadStdout: &localHad_stdout)
    let localHad_stdoutCopy = localHad_stdout
    syncQueue.sync {
      globalHad_stdout = localHad_stdoutCopy
    }
    
    semaphore.signal()
  }
  
  // Execute the cell, handle unexpected exceptions, and make sure to always 
  // clean up the stdout handler.
  var result: ExecutionResult
  do {
    defer {
      globalMessages.append("hello world 100.3")
      updateProgressFile()
      
      syncQueue.sync {
        doExecute_lock = true
      }
//       stdoutHandler.stop_event.set()
      globalMessages.append("hello world 100.4")
      updateProgressFile()
      
      semaphore.wait()
//       stdoutHandler.join()
      globalMessages.append("hello world 100.5")
      updateProgressFile()
    }
    globalMessages.append("hello world 100.1")
    updateProgressFile()
    
    result = try executeCell(code: code)
    globalMessages.append("hello world 100.2")
    updateProgressFile()
  } catch let error as PackageInstallException {
    let traceback = [error.localizedDescription]
    sendIOPubErrorMessage(traceback)
    return makeExecuteReplyErrorMessage(traceback)
  } catch {
    let kernel = KernelContext.kernel
    sendIOPubErrorMessage([
      "Kernel is in a bad state. Try restarting the kernel.",
      "",
      "Exception in cell \(kernel.execution_count):",
      error.localizedDescription
    ])
    throw error
  }
  
  // Send values/errors and status to the client.
  if result is SuccessWithValue {
    let kernel = KernelContext.kernel
    kernel.send_response(kernel.iopub_socket, "execute_result", [
      "execution_count": kernel.execution_count,
      "data": [
        "text/plain": result.description.pythonObject
      ],
      "metadata": [:]
    ])
    return nil
  } else if result is SuccessWithoutValue {
    return nil
  } else if result is ExecutionResultError {
    var traceback: [String]
    var isAlive: Int32 = 0
    _ = KernelContext.process_is_alive(&isAlive)
    
    if isAlive == 0 {
      traceback = ["Process killed"]
      sendIOPubErrorMessage(traceback)
      
      // Exit the kernel because there is no way to recover from a killed 
      // process. The UI will tell the user that the kernel has died and the UI 
      // will automatically restart the kernel. We do the exit in a callback so 
      // that this execute request can cleanly finish before the kernel exits.
      let loop = Python.import("ioloop").IOLoop.current()
      loop.add_timeout(Python.import("time").time() + 0.1, loop.stop)
    } else if syncQueue.sync(execute: { return globalHad_stdout }) {
//     } else if Bool(stdoutHandler.had_stdout)! {
      // When there is stdout, it is a runtime error. Stdout, which we have
      // already sent to the client, contains the error message (plus some other 
      // ugly traceback that we should eventually figure out how to suppress), 
      // so this block of code only needs to add a traceback.
      traceback = ["Current stack trace:"]
//       traceback += try prettyPrintStackTrace()
      sendIOPubErrorMessage(traceback)      
    } else {
      // There is no stdout, so it must be a compile error. Simply return the 
      // error without trying to get a stack trace.
      traceback = [result.description]
      sendIOPubErrorMessage(traceback)
    }
    
    return makeExecuteReplyErrorMessage(traceback)
  } else {
    fatalError("This should never happen.")
  }
}

fileprivate func setParentMessage() throws {
  let parentHeader = KernelContext.kernel._parent_header
  let jsonObj = json.dumps(json.dumps(jsonutil.squash_dates(parentHeader)))
  
  let result = execute(code: """
  JupyterKernel.communicator.updateParentMessage(
    to: KernelCommunicator.ParentMessage(json: \(String(jsonObj)!)))
  """)
  if result is ExecutionResultError {
    throw Exception("Error setting parent message: \(result)")
  }
}

fileprivate func prettyPrintStackTrace() throws -> [String] {
  var output: [String] = []
  
  var frames: UnsafeMutablePointer<UnsafeMutablePointer<CChar>>?
  var size: Int32 = 0
  let error = KernelContext.get_pretty_stack_trace(&frames, &size);
  guard let frames = frames else {
    throw Exception(
      "`get_pretty_stack_trace` failed with error code \(error).")
  }
  
  for i in 0..<Int(size) {
    let frame = frames[i]
    let description = String(cString: UnsafePointer(frame))
    var frameID = String(i + 1) + " "
    if frameID.count < 5 {
      frameID += String(repeating: " " as Character, count: 5 - frameID.count)
    }
    output.append(frameID + description)
    free(frame)
  }
  free(frames)
  return output
}

fileprivate func makeExecuteReplyErrorMessage(_ message: [String]) -> PythonObject {
  return [
    "status": "error",
    "execution_count": KernelContext.kernel.execution_count,
    "ename": "",
    "evalue": "",
    "traceback": message.pythonObject
  ]
}

fileprivate func sendIOPubErrorMessage(_ message: [String]) {
  let kernel = KernelContext.kernel
  kernel.send_response(kernel.iopub_socket, "error", [
    "ename": "",
    "evalue": "",
    "traceback": message.pythonObject
  ])
}

fileprivate func executeCell(code: String) throws -> ExecutionResult {
  globalMessages.append("hello world 200.0")
  updateProgressFile()
  
  try setParentMessage()
  globalMessages.append("hello world 200.1")
  updateProgressFile()
  
  let result = try preprocessAndExecute(code: code, isCell: true)
  globalMessages.append("hello world 200.2")
  updateProgressFile()
  
  if result is ExecutionResultSuccess {
    try afterSuccessfulExecution()
    globalMessages.append("hello world 200.3")
    updateProgressFile()
  }
  globalMessages.append("hello world 200.4")
  updateProgressFile()
  
  return result
}