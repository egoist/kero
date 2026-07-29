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
