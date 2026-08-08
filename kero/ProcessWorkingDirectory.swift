//
//  ProcessWorkingDirectory.swift
//  kero
//

import Darwin
import Foundation

/// A process's current working directory, read from kernel metadata.
///
/// A backend that reports OSC 7 tells Kero where the shell thinks it is, which
/// is authoritative and free. This is the fallback while a backend is waiting
/// for its first report, and the backstop for shells with no OSC 7 integration.
func processWorkingDirectory(pid: pid_t) -> String? {
    guard pid > 0 else { return nil }
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
        return nil
    }
    let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
        String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
    }
    return path.isEmpty ? nil : path
}

/// Absolute executable path for a live process. Agent recognition intentionally
/// uses the kernel-reported image rather than tab titles or shell command text,
/// both of which are user-controlled terminal output.
func processExecutablePath(pid: pid_t) -> String? {
    guard pid > 0 else { return nil }
    // PROC_PIDPATHINFO_MAXSIZE is a C arithmetic macro Swift does not import;
    // Darwin defines it as four MAXPATHLEN buffers (4096 bytes).
    var buffer = [CChar](repeating: 0, count: 4_096)
    let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard count > 0 else { return nil }
    let path = String(cString: buffer)
    return path.isEmpty ? nil : path
}

/// Kernel-reported argv for a live process. This is the companion to
/// `processExecutablePath(pid:)` for script-backed CLIs: macOS reports `node`
/// or `python` as their executable image, while argv still identifies the
/// script the shell actually launched.
func processArguments(pid: pid_t) -> [String]? {
    guard pid > 0 else { return nil }
    var name = [Int32(CTL_KERN), Int32(KERN_PROCARGS2), pid]
    var size = 0
    guard sysctl(&name, u_int(name.count), nil, &size, nil, 0) == 0,
          size >= MemoryLayout<Int32>.size
    else { return nil }

    // A process can change argv between the size and value calls. Give the
    // kernel a little headroom, then honor the returned byte count.
    var bytes = [UInt8](repeating: 0, count: size + 4_096)
    size = bytes.count
    guard sysctl(&name, u_int(name.count), &bytes, &size, nil, 0) == 0,
          size >= MemoryLayout<Int32>.size
    else { return nil }
    bytes.removeSubrange(size..<bytes.count)

    let argumentCount = bytes.withUnsafeBytes {
        Int($0.loadUnaligned(as: Int32.self))
    }
    guard argumentCount > 0, argumentCount <= 4_096 else { return nil }

    var cursor = MemoryLayout<Int32>.size
    // KERN_PROCARGS2 starts with the executable path, followed by padding and
    // then argc NUL-terminated argument strings.
    while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
    while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }

    var result: [String] = []
    result.reserveCapacity(min(argumentCount, 32))
    while cursor < bytes.count, result.count < argumentCount {
        let start = cursor
        while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
        guard cursor > start else { break }
        result.append(String(decoding: bytes[start..<cursor], as: UTF8.self))
        cursor += 1
    }
    return result.isEmpty ? nil : result
}
