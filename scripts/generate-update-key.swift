#!/usr/bin/env swift
// scripts/generate-update-key.swift
// 사용법: swift scripts/generate-update-key.swift [개인키 경로]
// 개인키(base64 32바이트)를 0600으로 저장하고 공개키 base64를 출력한다. 리포에는 공개키만 들어간다.
import CryptoKit
import Foundation

let defaultPath = NSString(string: "~/.wattly/update-signing.key").expandingTildeInPath
let path = CommandLine.arguments.dropFirst().first ?? defaultPath
let fm = FileManager.default

if fm.fileExists(atPath: path) {
    FileHandle.standardError.write(Data("refusing to overwrite existing key at \(path)\n".utf8))
    exit(1)
}

let key = Curve25519.Signing.PrivateKey()
let directory = (path as NSString).deletingLastPathComponent
try fm.createDirectory(atPath: directory, withIntermediateDirectories: true,
                       attributes: [.posixPermissions: 0o700])
try key.rawRepresentation.base64EncodedString().write(toFile: path, atomically: true, encoding: .utf8)
try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

print("private key written to \(path) — back it up; it is NOT in the repo")
print("public key for Wattly/Core/UpdateSigningKey.swift:")
print(key.publicKey.rawRepresentation.base64EncodedString())
