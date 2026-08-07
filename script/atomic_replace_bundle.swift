#!/usr/bin/env swift

import Darwin
import Foundation

let arguments = CommandLine.arguments
 guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: atomic_replace_bundle.swift CURRENT REPLACEMENT\n".utf8))
    exit(2)
}

let current = arguments[1]
let replacement = arguments[2]
let manager = FileManager.default

func fail(_ operation: String) -> Never {
    let message = String(cString: strerror(errno))
    FileHandle.standardError.write(Data("\(operation): \(message)\n".utf8))
    exit(1)
}

if manager.fileExists(atPath: current) {
    guard renameatx_np(AT_FDCWD, current, AT_FDCWD, replacement, UInt32(RENAME_SWAP)) == 0 else {
        fail("atomic bundle exchange failed")
    }
} else {
    guard rename(replacement, current) == 0 else {
        fail("atomic bundle publication failed")
    }
}
